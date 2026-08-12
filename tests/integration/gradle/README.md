# Real Gradle and Android fixture

Run the explicit integration gate from the repository root:

```sh
make test-integration-gradle
```

The script creates disposable projects for Gradle 7.3.3 with AGP 7.1.3 and
Gradle 9.1.0 with AGP 9.0.1. For each endpoint it runs the shipped discovery
provider twice with configuration cache enabled, resolves a task in an included
build, executes that exact task through the public facade, and assembles the
fixture Android application.

The gate needs an Android SDK containing platforms 30 and 36, a Java 17 runtime,
`curl`, and `unzip`. It uses an exact Gradle distribution already present under
`GRADLE_USER_HOME` when available. Otherwise it downloads the official archive
into the disposable test directory and verifies its published SHA-256 digest.
Gradle and AGP dependency caches remain external; project state and build output
are deleted when the script exits.
