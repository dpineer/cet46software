# Flutter wrapper
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Flutter Play Store Split
-keep class com.google.android.play.core.splitcompat.** { *; }
-keep class com.google.android.play.core.splitinstall.** { *; }
-keep class com.google.android.play.core.tasks.** { *; }
-dontwarn com.google.android.play.core.**

# Google ML Kit
-dontwarn com.google.mlkit.**
-keep class com.google.mlkit.** { *; }
-keep class com.google.android.gms.** { *; }

# Chinese Text Recognizer
-dontwarn com.google.mlkit.vision.text.chinese.**
-keep class com.google.mlkit.vision.text.chinese.** { *; }
-keep class com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions$Builder { *; }
-keep class com.google.mlkit.vision.text.chinese.ChineseTextRecognizerOptions { *; }

# Devanagari Text Recognizer
-dontwarn com.google.mlkit.vision.text.devanagari.**
-keep class com.google.mlkit.vision.text.devanagari.** { *; }
-keep class com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions$Builder { *; }
-keep class com.google.mlkit.vision.text.devanagari.DevanagariTextRecognizerOptions { *; }

# Japanese Text Recognizer
-dontwarn com.google.mlkit.vision.text.japanese.**
-keep class com.google.mlkit.vision.text.japanese.** { *; }
-keep class com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions$Builder { *; }
-keep class com.google.mlkit.vision.text.japanese.JapaneseTextRecognizerOptions { *; }

# Korean Text Recognizer
-dontwarn com.google.mlkit.vision.text.korean.**
-keep class com.google.mlkit.vision.text.korean.** { *; }
-keep class com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions$Builder { *; }
-keep class com.google.mlkit.vision.text.korean.KoreanTextRecognizerOptions { *; }

# General Google ML Kit Vision
-dontwarn com.google.mlkit.vision.**
-keep class com.google.mlkit.vision.** { *; }