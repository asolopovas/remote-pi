#!/usr/bin/env bash
# Compiles production Kotlin using the cached release Gradle seam, then runs
# its actual class files on the JVM with explicit Android/Flutter test doubles.
set -euo pipefail
cd "$(dirname "$0")/../../.."
export ANDROID_HOME=/home/andrius/Android/Sdk JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64
out=build/76-voice/native-fix/jvm
mkdir -p "$out/classes"
(cd android && ./gradlew --offline :speech_to_text:compileReleaseKotlin -Pkotlin.incremental=false)
cache="$HOME/.gradle/caches/modules-2/files-2.1"
flutter=$(find "$cache/io.flutter/flutter_embedding_release/1.0.0-a10d8ac38de835021c8d2f920dbf50a920ccc030" -name '*.jar' -print -quit)
kotlin=$(find "$cache/org.jetbrains.kotlin/kotlin-stdlib/2.2.20" -name '*.jar' -print -quit)
android="$ANDROID_HOME/platforms/android-36/android.jar"
production=build/speech_to_text/tmp/kotlin-classes/release
cp="$production:$flutter:$kotlin:$android"
find test/native/speech_to_text -name '*.java' -print0 | xargs -0 "$JAVA_HOME/bin/javac" -cp "$cp" -d "$out/classes"
"$JAVA_HOME/bin/java" -cp "$out/classes:$cp" SpeechToTextPluginTest
