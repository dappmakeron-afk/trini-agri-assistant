# Preserve generic signatures (Crucial for the "Missing type parameter" error)
-keepattributes Signature
-keep,allowobfuscation,allowshrinking class com.google.gson.reflect.TypeToken
-keep,allowobfuscation,allowshrinking class * extends com.google.gson.reflect.TypeToken

# Keep the notification plugin classes
-keep class com.dexterous.flutterlocalnotifications.** { *; }
