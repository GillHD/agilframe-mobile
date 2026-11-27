<#
.SYNOPSIS
  Reproduces the Android SDK verification on a host that only has JDK 8, a
  cached Kotlin 1.6 compiler and Android platform 31 (no Gradle 8 / JDK 17).

.DESCRIPTION
  Compiles the core sources against `android-31/android.jar`, then compiles
  the sources together with the JUnit tests (a single Kotlin module so the
  `internal` bridge APIs are visible) and runs JUnit 4.

  This is a fallback for the authoring/QA environment described in
  `docs/android-sdk.md`; the canonical build remains
  `gradle :agil-calls:testDebugUnitTest` with JDK 17.

  Required cached artifacts (override the root with $env:GRADLE_CACHE):
    org.jetbrains.kotlin:kotlin-compiler-embeddable:1.6.0
    org.jetbrains.kotlin:kotlin-stdlib:1.6.0
    org.jetbrains.kotlin:kotlin-reflect:1.6.0
    org.jetbrains.kotlin:kotlin-script-runtime:1.6.0
    org.jetbrains.intellij.deps:trove4j:1.0.20181211
    org.jetbrains:annotations:13.0
    junit:junit:4.13.2, org.hamcrest:hamcrest-core:1.3
    org.json:json:20180813
  and an Android SDK with `platforms/android-31/android.jar` ($env:ANDROID_HOME
  or $env:LOCALAPPDATA\Android\Sdk).

.EXAMPLE
  pwsh agil/mobile/android/scripts/verify-jvm.ps1
#>
param(
    [string]$Repo = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..\..")).Path,
    [string]$Out = "",
    [string]$Cache = $(if ($env:GRADLE_CACHE) { $env:GRADLE_CACHE } else { Join-Path $env:USERPROFILE ".gradle\caches" })
)

$ErrorActionPreference = "Stop"
if (-not $Out) { $Out = Join-Path $Repo ".tmp\android-verify" }
$modules = Join-Path $Cache "modules-2\files-2.1"

function Find-Jar([string]$relative, [string]$filter) {
    $dir = Join-Path $modules $relative
    $jar = Get-ChildItem -Path $dir -Recurse -Filter $filter -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -notmatch "sources|javadoc" } |
        Select-Object -First 1
    if (-not $jar) { throw "Missing jar '$filter' under $dir" }
    return $jar.FullName
}

$kc = Find-Jar "org.jetbrains.kotlin\kotlin-compiler-embeddable\1.6.0" "kotlin-compiler-embeddable-1.6.0.jar"
$stdlib = Find-Jar "org.jetbrains.kotlin\kotlin-stdlib\1.6.0" "kotlin-stdlib-1.6.0.jar"
$reflect = Find-Jar "org.jetbrains.kotlin\kotlin-reflect\1.6.0" "kotlin-reflect-1.6.0.jar"
$script = Find-Jar "org.jetbrains.kotlin\kotlin-script-runtime\1.6.0" "kotlin-script-runtime-1.6.0.jar"
$trove = Find-Jar "org.jetbrains.intellij.deps\trove4j\1.0.20181211" "trove4j-1.0.20181211.jar"
$annot = Get-ChildItem -Path $Cache -Recurse -Filter "annotations-13.0.jar" -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $annot) { throw "Missing annotations-13.0.jar under $Cache" }
$junit = Find-Jar "junit\junit\4.13.2" "junit-4.13.2.jar"
$hamcrest = Find-Jar "org.hamcrest\hamcrest-core\1.3" "hamcrest-core-1.3.jar"
$json = Find-Jar "org.json\json\20180813" "json-20180813.jar"

$sdk = if ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA "Android\Sdk" }
$androidJar = Join-Path $sdk "platforms\android-31\android.jar"
if (-not (Test-Path $androidJar)) { throw "android-31/android.jar not found at $androidJar" }

$compilerCp = @($kc, $stdlib, $reflect, $script, $trove, $annot.FullName) -join ";"
$mainOut = Join-Path $Out "main"
$combinedOut = Join-Path $Out "combined"
Remove-Item -Recurse -Force $mainOut, $combinedOut -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $mainOut, $combinedOut | Out-Null

$srcDir = Join-Path $Repo "agil\mobile\android\agil-calls\src\main\java\com\agilcalls\sdk"
$testDir = Join-Path $Repo "agil\mobile\android\agil-calls\src\test\java\com\agilcalls\sdk"
$mainSources = @(Get-ChildItem "$srcDir\*.kt" | Select-Object -ExpandProperty FullName)
$testSources = @(Get-ChildItem "$testDir\*.kt" | Select-Object -ExpandProperty FullName)
if ($mainSources.Count -eq 0) { throw "No main sources under $srcDir" }

Write-Output "=== Compile $($mainSources.Count) main sources against android-31 ==="
& java -cp $compilerCp org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect `
    -jvm-target 1.8 -module-name agil-calls -classpath "$stdlib;$androidJar" -d $mainOut @mainSources
if ($LASTEXITCODE -ne 0) { throw "main compile failed ($LASTEXITCODE)" }
Write-Output "MAIN COMPILE OK: $((Get-ChildItem $mainOut -Recurse -Filter *.class).Count) classes"

Write-Output "=== Compile main + $($testSources.Count) test sources ==="
& java -cp $compilerCp org.jetbrains.kotlin.cli.jvm.K2JVMCompiler -no-stdlib -no-reflect `
    -jvm-target 1.8 -module-name agil-calls -classpath "$stdlib;$androidJar;$junit;$json" `
    -d $combinedOut @($mainSources + $testSources)
if ($LASTEXITCODE -ne 0) { throw "test compile failed ($LASTEXITCODE)" }

Write-Output "=== Run JUnit 4 ==="
# android.jar is last: the real org.json implementation must win over the stub.
$runCp = @($combinedOut, $stdlib, $junit, $hamcrest, $json, $androidJar) -join ";"
$classes = @(
    "com.agilcalls.sdk.AgilCallUrlTest",
    "com.agilcalls.sdk.AgilTokenRedactorTest",
    "com.agilcalls.sdk.AgilBridgeProtocolTest",
    "com.agilcalls.sdk.AgilBridgeEnvelopeTest",
    "com.agilcalls.sdk.AgilBridgeScriptTest",
    "com.agilcalls.sdk.AgilClientTest",
    "com.agilcalls.sdk.AgilLargeRoomTest"
)
& java -cp $runCp org.junit.runner.JUnitCore @classes
$exit = $LASTEXITCODE
if ($exit -ne 0) { throw "JUnit failed ($exit)" }
Write-Output "=== JVM verification PASSED ==="
