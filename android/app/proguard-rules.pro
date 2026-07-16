# ML Kit barcode scanning (used by the mobile_scanner plugin for the QR
# importer). The plugin's bundled consumer rules keep only single-level
# wildcards (com.google.mlkit.*), which leaves ML Kit's internal subpackages
# free for R8 to strip or rename. On release builds the scanner then crashes
# at native start, before the camera opens, with an NPE in obfuscated code
# ("Attempt to invoke virtual method ... on a null object reference").
# Keep the whole ML Kit surface plus the native barcode pipeline it loads.
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_barcode.** { *; }
-keep class com.google.android.gms.internal.mlkit_vision_common.** { *; }
-keep class com.google.android.odml.image.** { *; }
-keep class com.google.android.libraries.barhopper.** { *; }
-dontwarn com.google.mlkit.**
-dontwarn com.google.android.odml.image.**
