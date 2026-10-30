# R8 shrinks the libraries (Guava, protobuf, Media3, coroutines...) and leaves what is reached by name alone.

# NewPipeExtractor and Rhino (which it runs the player's scripts with) reach parts of themselves by name
-keep class org.schabi.newpipe.** { *; }
-keep class org.mozilla.javascript.** { *; }

# Our own code: the Flutter bridge, the services the manifest names, the workers WorkManager makes by name and the
# classes kotlinx.serialization and org.json read by name. It is small next to the libraries.
-keep class app.sapoche.** { *; }

# Rhino also has parts for a desktop JVM that need classes Android does not have; they are never reached here
-dontwarn java.beans.**
-dontwarn javax.script.**
-dontwarn jdk.dynalink.**

# WorkManager keeps its jobs in a Room database that Room makes by name, and makes the workers by name too (it is what
# stopped the app at the very start when these were not kept)
-keep class * extends androidx.room.RoomDatabase { <init>(); }
-keep class * extends androidx.work.ListenableWorker { <init>(...); }
