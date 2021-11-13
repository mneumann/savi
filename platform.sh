#!/usr/bin/env sh

set -e

fail() {
  >&2 echo $@
  exit 1
}

# We support a limited set of platforms in our binary builds.
# Other platforms will need to build from source instead of using asdf.
if uname | grep -iq 'Linux'; then
  if uname -m | grep -iq 'x86_64'; then
    if getconf GNU_LIBC_VERSION > /dev/null 2>&1; then
      echo 'x86_64-unknown-linux-gnu'
    elif ldd --version 2>&1 | grep -iq musl; then
      echo 'x86_64-unknown-linux-musl'
    else
      fail "On Linux, the supported libc variants are: gnu, musl"
    fi
  else
    fail "On Linux, the only curently supported arch is: x86_64"
  fi
  # TODO: Add FreeBSD when binary builds for it are supported.
elif uname | grep -iq 'Darwin'; then
  if uname -m | grep -iq 'x86_64'; then
    echo 'x86_64-apple-macosx'
  else
    # TODO: Add arm64 (M1) when binary builds for it are supported.
    fail "On Darwin, the only curently supported arch is: x86_64"
  fi
else
  fail "The only supported operating systems are: Linux, Darwin"
fi