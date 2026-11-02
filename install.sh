#!/bin/sh
# shellcheck shell=sh disable=SC3043
# installs pmg: bootstraps uv where missing, installs the latest tag of pmg into its own venv, and
# links a launcher to ~/.local/bin; `pmg self-upgrade` runs this again
# with PMG_INSTALL_LIB set, sourcing it only defines the functions, as zshsetup shares them
#
# PMG_VENV_DIR   the venv of pmg (default ~/.cache/pmg/venv)
# PMG_UV_DIR     where uv is bootstrapped, if none is in PATH (default ~/.cache/pmg/uv)
# PMG_TAG        a tag to install instead of the latest
# PMG_SOURCE     a local checkout to install editable instead of a tag
# XDG_BIN_HOME   where the launcher goes (default ~/.local/bin)

# the tag installed if git cannot find the latest, and the oldest one the launcher keeps
__PMG_TAG="v2.4.2"
__PMG_REPO="https://github.com/zshsetup/pmg"
__PMG_INSTALL_URL="https://github.com/zshsetup/pmg/raw/refs/heads/main/install.sh"

# checks whether the version of the tag $1 is at least that of $2, e.g. v1.10.0 and v1.9.2
__version_at_least() {
  local a b x y
  a="${1#v}"
  b="${2#v}"
  while [ -n "$a$b" ]; do
    x="${a%%.*}"
    y="${b%%.*}"
    case "${x:-0}${y:-0}" in
      *[!0-9]*) return 1 ;;
    esac
    [ "${x:-0}" -gt "${y:-0}" ] && return 0
    [ "${x:-0}" -lt "${y:-0}" ] && return 1
    case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
    case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
  done
}

# prints the latest vX.Y.Z tag of pmg, with git, which has no API limit
__latest_pmg_tag() {
  local tag latest
  latest=""
  for tag in $(git ls-remote --tags --refs "$__PMG_REPO" 'v*' 2>/dev/null | sed 's|.*refs/tags/||'); do
    case "$tag" in
      v*[!0-9.]* | v | v.* | *..* | *.) continue ;;
    esac
    if [ -z "$latest" ] || __version_at_least "$tag" "$latest"; then
      latest="$tag"
    fi
  done
  [ -n "$latest" ] && echo "$latest"
}

# prints the Python for pmg with the uv $1: an installed one from 3.10 on, outside of any venv,
# if it has the tarfile data filter (backported to 3.10.12 and 3.11.4), else 3.12 for uv to install
__pmg_python() {
  local python
  if python="$("$1" python find --system --no-project '>=3.10' 2>/dev/null)" \
    && "$python" -c 'import tarfile; tarfile.data_filter' 2>/dev/null; then
    echo "$python"
  else
    echo 3.12
  fi
}

# prints the path of an executable in PATH without running it, ignoring functions and aliases
__which() {
  local dir IFS
  IFS=:
  for dir in $PATH; do
    if [ -f "${dir:-.}/$1" ] && [ -x "${dir:-.}/$1" ]; then
      echo "${dir:-.}/$1"
      return 0
    fi
  done
  return 1
}

# checks whether an executable is in PATH
__available() {
  local cmd_path
  cmd_path="$(__which "$1")" || return 1
  # the stubs of macOS in /usr/bin (git, make, cc, ...) only offer to install missing developer
  # tools
  if [ "$(uname)" = "Darwin" ] && [ "$cmd_path" -ef /usr/bin/cc ] && ! /usr/bin/xcode-select -p >/dev/null 2>&1; then
    return 1
  fi
}

# installs pmg from a spec, the archive of a tag or a local checkout (installed editable), into the
# venv that the launcher runs, with an installed Python, else 3.12 of uv; the source is written
# last, so an interrupted install is redone
__install_pmg_venv() {
  local uv venv source spec
  uv="$1"
  venv="$2"
  source="$3"
  spec="$4"
  "$uv" venv --quiet --clear --python "$(__pmg_python "$uv")" "$venv" || return 1
  if [ -d "$spec" ]; then
    "$uv" pip install --quiet --python "$venv/bin/python" --editable "$spec" || return 1
  else
    "$uv" pip install --quiet --python "$venv/bin/python" "$spec" || return 1
  fi
  printf '%s\n' "$source" >"$venv/.source"
}

# prints a URL with curl, wget, python3, or apt-helper, for bootstrapping uv
__download() {
  local tmp
  if __available curl; then
    curl -fsSL "$1"
  elif __available wget; then
    wget -q -O - "$1"
  elif __available python3; then
    python3 -c 'import shutil, sys, urllib.request; res = urllib.request.urlopen(sys.argv[1]); shutil.copyfileobj(res, sys.stdout.buffer)' "$1"
  elif [ -x "/usr/lib/apt/apt-helper" ]; then
    # without CA certificates, the checksum of uv still guards the download
    tmp="$(mktemp)"
    if ! /usr/lib/apt/apt-helper -o Acquire::https::Verify-Peer=false download-file "$1" "$tmp" >/dev/null 2>&1; then
      rm -f "$tmp"
      return 1
    fi
    cat "$tmp"
    rm -f "$tmp"
  else
    echo "curl, wget, python3, or apt-helper required!" >&2
    return 1
  fi
}

# the gnu build of uv needs glibc 2.28, older glibc and musl get the static musl build
__uv_libc() {
  local glibc minor
  glibc="$(getconf GNU_LIBC_VERSION 2>/dev/null | cut -d ' ' -f 2)"
  minor="${glibc#2.}"
  if [ -n "$glibc" ] && [ "${minor%%.*}" -ge 28 ]; then
    echo gnu
  else
    echo musl
  fi
}

# installs a fixed uv into $1, checked against its sha256
__bootstrap_uv() {
  local target sha256 asset url uv_tmp actual rc
  case "$(uname -s)-$(uname -m)-$(__uv_libc)" in
    Linux-x86_64-gnu) target="x86_64-unknown-linux-gnu" sha256="23bf5552d220e0842b65c862097b2ebaeba0064b74eda5e565e77fd25969d8c8" ;;
    Linux-aarch64-gnu) target="aarch64-unknown-linux-gnu" sha256="0804e9b164c64b6914182d5920c08551958a095986f10a3731056df701126436" ;;
    Linux-x86_64-musl) target="x86_64-unknown-linux-musl" sha256="db7278c9f57981338fddff1fb250e11964bc0a4fafcb9eed8303fdb117dc067b" ;;
    Linux-aarch64-musl) target="aarch64-unknown-linux-musl" sha256="ad8d8448a2ff642ba62c2f684d7dd22a03f8eb3fc9918c2c3e8ec975f4ed6710" ;;
    Darwin-arm64-*) target="aarch64-apple-darwin" sha256="a9a8df1eedeb192f2e47e40e2faabfb387db4b850209118786d42f89dde3e0ba" ;;
    *)
      echo "no uv for $(uname -s) $(uname -m)" >&2
      return 1
      ;;
  esac
  asset="uv-$target.tar.gz"
  url="https://github.com/astral-sh/uv/releases/download/0.12.19/$asset"
  uv_tmp="$(mktemp -d)"
  __download "$url" >"$uv_tmp/$asset" || {
    rm -rf "$uv_tmp"
    return 1
  }
  if __available sha256sum; then
    actual="$(sha256sum "$uv_tmp/$asset" | cut -d ' ' -f 1)"
  else
    actual="$(shasum -a 256 "$uv_tmp/$asset" | cut -d ' ' -f 1)"
  fi
  if [ "$actual" != "$sha256" ]; then
    echo "sha256 mismatch for $url" >&2
    rm -rf "$uv_tmp"
    return 1
  fi
  tar -xzf "$uv_tmp/$asset" -C "$uv_tmp" && mkdir -p "$1" && mv "$uv_tmp/${asset%.tar.gz}/uv" "$1/uv"
  rc=$?
  rm -rf "$uv_tmp"
  return "$rc"
}

# writes the launcher $1, which runs pmg from its venv and upgrades it with self-upgrade
__write_launcher() {
  local tmp
  mkdir -p "${1%/*}" || return 1
  tmp="$(mktemp "$1.XXXXXX")" || return 1
  cat >"$tmp" <<'LAUNCHER'
#!/bin/sh
# runs pmg from its own venv; `pmg self-upgrade` installs the latest tag of pmg, see install.sh
set -eu

venv="${PMG_VENV_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/pmg/venv}"

# GitHub token for the API rate limit, only for the subcommands that download
if [ -z "${PMG_GH_TOKEN:-}${GH_TOKEN:-}${GITHUB_TOKEN:-}" ]; then
  case "${1:-}" in
  install | upgrade | update | self-upgrade)
    if command -v gh >/dev/null 2>&1; then
      PMG_GH_TOKEN="$(gh auth token 2>/dev/null || true)"
      export PMG_GH_TOKEN
    fi
    ;;
  esac
fi

if [ "${1:-}" = self-upgrade ]; then
  script="$(mktemp)"
  # with the certificates of certifi, a dependency of pmg, as the system may have none
  "$venv/bin/python" -c 'import shutil, ssl, sys, urllib.request, certifi
context = ssl.create_default_context(cafile=certifi.where())
shutil.copyfileobj(urllib.request.urlopen(sys.argv[1], context=context), sys.stdout.buffer)' \
    "${PMG_INSTALL_URL:-__PMG_INSTALL_URL__}" >"$script" || {
    rm -f "$script"
    echo "Failed to download the installer of pmg" >&2
    exit 1
  }
  PMG_VENV_DIR="$venv" sh "$script"
  rc=$?
  rm -f "$script"
  exit "$rc"
fi

# python -m pmg, as the pmg script of uv needs a realpath with --, which BusyBox (Alpine) lacks
exec "$venv/bin/python" -m pmg "$@"
LAUNCHER
  sed "s|__PMG_INSTALL_URL__|$__PMG_INSTALL_URL|" "$tmp" >"$tmp.sed" && mv "$tmp.sed" "$tmp" \
    && chmod 755 "$tmp" && mv "$tmp" "$1"
}

__install_main() {
  local cache uv venv installed source spec bin
  if [ -z "$HOME" ]; then
    echo "HOME must be set" >&2
    exit 1
  fi

  if [ "$(uname)" = "Darwin" ] && [ "$(uname -m)" != "arm64" ]; then
    echo "Only macOS arm64 is supported" >&2
    exit 1
  fi

  cache="${XDG_CACHE_HOME:-$HOME/.cache}"
  venv="${PMG_VENV_DIR:-$cache/pmg/venv}"
  bin="${XDG_BIN_HOME:-$HOME/.local/bin}"

  # the source to install: a local checkout, a given tag, or the archive of the latest tag, as uv
  # would need git for a git URL; the fallback tag if git cannot tell
  if [ -n "${PMG_SOURCE:-}" ]; then
    source="$PMG_SOURCE"
    spec="$PMG_SOURCE"
  else
    source="${PMG_TAG:-$(__latest_pmg_tag || true)}"
    __version_at_least "$source" "$__PMG_TAG" || source="$__PMG_TAG"
    spec="$__PMG_REPO/archive/refs/tags/$source.tar.gz"
  fi

  installed="$(cat "$venv/.source" 2>/dev/null || true)"
  if [ -x "$venv/bin/python" ] && [ "$installed" = "$source" ]; then
    echo "pmg $source is the latest" >&2
  else
    uv="$(__which uv || true)"
    if [ -z "$uv" ]; then
      uv="${PMG_UV_DIR:-$cache/pmg/uv}/uv"
      if [ ! -x "$uv" ] && ! __bootstrap_uv "${uv%/uv}"; then
        echo "Failed to bootstrap uv" >&2
        exit 1
      fi
    fi
    if ! __install_pmg_venv "$uv" "$venv" "$source" "$spec"; then
      echo "Failed to install pmg" >&2
      exit 1
    fi
    echo "installed pmg $source" >&2
  fi

  if ! __write_launcher "$bin/pmg"; then
    echo "Failed to write $bin/pmg" >&2
    exit 1
  fi
  case ":$PATH:" in
    *":$bin:"*) ;;
    *) echo "add $bin to PATH to run pmg" >&2 ;;
  esac
}

if [ -z "${PMG_INSTALL_LIB:-}" ]; then
  __install_main
fi
