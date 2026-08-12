#!/bin/sh
set -eu

integration_root=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
checkout=$(CDPATH='' cd -- "$integration_root/../../.." && pwd)
fixture_root="$integration_root/fixture"
work_root=$(mktemp -d "${TMPDIR:-/tmp}/android-workbench-gradle.XXXXXX")
trap 'rm -rf "$work_root"' EXIT HUP INT TERM

sdk_root=${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}
if [ -z "$sdk_root" ] || [ ! -d "$sdk_root" ]; then
  echo 'ANDROID_SDK_ROOT or ANDROID_HOME must name an installed Android SDK.' >&2
  exit 1
fi

java_home=${AWB_JAVA_HOME:-}
if [ -z "$java_home" ] && [ -x /usr/libexec/java_home ]; then
  java_home=$(/usr/libexec/java_home -v 17)
fi
if [ -z "$java_home" ] && [ "$(java -version 2>&1 | sed -n '1s/.*version "\([0-9]*\).*/\1/p')" = '17' ]; then
  java_home=$(CDPATH='' cd -- "$(dirname -- "$(command -v java)")/.." && pwd)
fi
if [ ! -x "$java_home/bin/java" ]; then
  echo 'A Java 17 runtime is required; set AWB_JAVA_HOME to its home directory.' >&2
  exit 1
fi
if ! "$java_home/bin/java" -version 2>&1 | sed -n '1p' | grep -Eq 'version "17([.]|\")'; then
  echo 'AWB_JAVA_HOME must point to Java 17.' >&2
  exit 1
fi

gradle_home=${GRADLE_USER_HOME:-$HOME/.gradle}

gradle_checksum() {
  case "$1" in
    7.3.3) echo 'b586e04868a22fd817c8971330fec37e298f3242eb85c374181b12d637f80302' ;;
    9.1.0) echo 'a17ddd85a26b6a7f5ddb71ff8b05fc5104c0202c6e64782429790c933686c806' ;;
    *) return 1 ;;
  esac
}

resolve_gradle() {
  version=$1
  resolved_gradle=
  distribution_root="$gradle_home/wrapper/dists/gradle-$version-bin"
  if [ -d "$distribution_root" ]; then
    candidate=$(find "$distribution_root" -type f -path "*/gradle-$version/bin/gradle" -print | sed -n '1p')
    if [ -x "$candidate" ]; then
      resolved_gradle=$candidate
      return
    fi
  fi

  archive="$work_root/gradle-$version-bin.zip"
  distribution="$work_root/distributions/gradle-$version"
  mkdir -p "$work_root/distributions"
  curl -fL "https://services.gradle.org/distributions/gradle-$version-bin.zip" -o "$archive"
  expected=$(gradle_checksum "$version")
  if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$archive" | awk '{ print $1 }')
  else
    actual=$(shasum -a 256 "$archive" | awk '{ print $1 }')
  fi
  if [ "$actual" != "$expected" ]; then
    echo "Gradle $version archive checksum mismatch." >&2
    exit 1
  fi
  unzip -q "$archive" -d "$work_root/distributions"
  resolved_gradle="$distribution/bin/gradle"
}

render() {
  source_file=$1
  target_file=$2
  agp_version=$3
  compile_sdk=$4
  sed \
    -e "s/@AGP_VERSION@/$agp_version/g" \
    -e "s/@COMPILE_SDK@/$compile_sdk/g" \
    "$source_file" > "$target_file"
}

run_endpoint() {
  name=$1
  gradle_version=$2
  agp_version=$3
  compile_sdk=$4
  resolve_gradle "$gradle_version"

  project="$work_root/$name/project"
  xdg_root="$work_root/$name/xdg"
  mkdir -p "$project" "$xdg_root/config" "$xdg_root/data" "$xdg_root/state" "$xdg_root/cache"
  cp -R "$fixture_root/." "$project"
  render "$fixture_root/build.gradle.in" "$project/build.gradle" "$agp_version" "$compile_sdk"
  render "$fixture_root/app/build.gradle.in" "$project/app/build.gradle" "$agp_version" "$compile_sdk"
  rm "$project/build.gradle.in" "$project/app/build.gradle.in"
  printf 'sdk.dir=%s\n' "$sdk_root" > "$project/local.properties"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$resolved_gradle" > "$project/gradlew"
  chmod 700 "$project/gradlew"

  reported_version=$(env JAVA_HOME="$java_home" "$project/gradlew" --version | sed -n 's/^Gradle \(.*\)$/\1/p')
  if [ "$reported_version" != "$gradle_version" ]; then
    echo "Expected Gradle $gradle_version, got $reported_version." >&2
    exit 1
  fi

  echo "==> Gradle $gradle_version / AGP $agp_version"
  env \
    ANDROID_HOME="$sdk_root" \
    ANDROID_SDK_ROOT="$sdk_root" \
    ANDROID_WORKBENCH_TEST_ROOT="$checkout" \
    AWB_FIXTURE_AGP="$agp_version" \
    AWB_FIXTURE_GRADLE="$gradle_version" \
    AWB_FIXTURE_ROOT="$project" \
    GRADLE_USER_HOME="$gradle_home" \
    JAVA_HOME="$java_home" \
    NVIM_APPNAME=android-workbench-integration \
    XDG_CACHE_HOME="$xdg_root/cache" \
    XDG_CONFIG_HOME="$xdg_root/config" \
    XDG_DATA_HOME="$xdg_root/data" \
    XDG_STATE_HOME="$xdg_root/state" \
    nvim --headless -u "$checkout/tests/minimal_init.lua" -i NONE \
      "+luafile $integration_root/verify.lua"
}

run_endpoint floor 7.3.3 7.1.3 30
run_endpoint current 9.1.0 9.0.1 36
