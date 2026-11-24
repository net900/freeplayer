# bvc2_bridge.cpp looks these members up by name from JNI, so R8 must keep
# them even though no Java code calls them directly.
-keep class androidx.media3.decoder.VideoDecoderOutputBuffer { *; }
-keep class androidx.media3.decoder.DecoderOutputBuffer { *; }

# cenc_jni.cpp exports Java_cn_freeplayer_app_cenc_CencNative_*, so the class
# and its native methods must keep their names.
-keep class cn.freeplayer.app.cenc.CencNative { *; }
