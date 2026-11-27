# Consumer rules shipped inside the AAR (applied automatically by R8/ProGuard).
#
# Keep the public API and, most importantly, JavascriptInterface methods: R8
# renames methods by default, which would break window.AgilCallsBridge.

-keep public class com.agilcalls.sdk.AgilCallView { public *; }
-keep public class com.agilcalls.sdk.AgilCallConfig { public *; }
-keep public class com.agilcalls.sdk.AgilCallTarget { public *; }
-keep public class com.agilcalls.sdk.AgilTheme { *; }
-keep public class com.agilcalls.sdk.AgilRole { *; }
-keep public class com.agilcalls.sdk.AgilCallEvent { *; }
-keep public class com.agilcalls.sdk.AgilCallEvent$* { *; }
-keep public class com.agilcalls.sdk.AgilCallError { *; }
-keep public class com.agilcalls.sdk.AgilCallError$* { *; }
-keep public class com.agilcalls.sdk.AgilCallSnapshot { *; }
-keep public class com.agilcalls.sdk.AgilChatMessage { *; }
-keep public class com.agilcalls.sdk.AgilCapabilities { *; }
-keep public class com.agilcalls.sdk.AgilClient { public *; }
-keep public class com.agilcalls.sdk.AgilClientConfig { public *; }
-keep public class com.agilcalls.sdk.AgilJoinRequest { public *; }
-keep public class com.agilcalls.sdk.AgilJoinResult { *; }
-keep public class com.agilcalls.sdk.AgilJoinResult$* { *; }
-keep public class com.agilcalls.sdk.AgilRoom { public *; }
-keep public class com.agilcalls.sdk.AgilParticipant { public *; }
-keep public class com.agilcalls.sdk.AgilJoinHandle { public *; }
-keep public class com.agilcalls.sdk.AgilCallConfigException { public *; }
-keep public class com.agilcalls.sdk.AgilJoinException { *; }
-keep public class com.agilcalls.sdk.AgilJoinException$* { *; }
-keep public interface com.agilcalls.sdk.AgilCallEventListener { *; }
-keep public interface com.agilcalls.sdk.AgilJoinCallback { *; }
-keep public class com.agilcalls.sdk.AgilTokenRedactor { public *; }

# The bridge relies on the runtime annotation (a custom rule set may strip it).
-keepattributes RuntimeVisibleAnnotations

# Do not rename @JavascriptInterface methods (the JS side calls them by name).
-keepclassmembers class * {
    @android.webkit.JavascriptInterface <methods>;
}
