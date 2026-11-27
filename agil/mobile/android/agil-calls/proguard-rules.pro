# Library release rules (consumer-rules.pro is what ships in the AAR).
-keep public class com.agilcalls.sdk.** { public *; }
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
