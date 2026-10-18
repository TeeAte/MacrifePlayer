//  ffmpeg_shim.h
//  MetalPlayer 重建工程 —— FFmpeg 7.1 C 接口统一入口
//
//  为什么需要这一层：
//    bundle 里带了 72 个 FFmpeg dylib，但**一个头文件都没带**。
//    Swift 不能直接 import C 动态库，必须经由 modulemap + 头文件。
//    这里把需要的公开头文件收拢成一个模块，供 `import CFFmpeg` 使用。
//
//  版本对齐（已实测核对）：
//    头文件  libavcodec 61.19.100 / libavformat 61.7.100 / libavutil 59.39.100
//    dylib   libavcodec 61.19.101 / libavformat 61.7.100 / libavutil 59.39.100
//    → 同 major/minor，micro 差 1（补丁级），ABI 兼容。
//    运行时 av_version_info() 实报 7.1.1。
//
//  注意：故意**不使用 umbrella directory**。
//  FFmpeg 的 libav*/ 目录里混有大量内部头文件（含 `#include "config.h"`），
//  umbrella 会把它们一并拉进来导致编译失败。这里显式列举。

#ifndef METALPLAYER_FFMPEG_SHIM_H
#define METALPLAYER_FFMPEG_SHIM_H

// ---------------- libavutil ----------------
#include "libavutil/avutil.h"
#include "libavutil/avconfig.h"
#include "libavutil/ffversion.h"
#include "libavutil/attributes.h"
#include "libavutil/avassert.h"
#include "libavutil/avstring.h"
#include "libavutil/base64.h"
#include "libavutil/bprint.h"
#include "libavutil/buffer.h"
#include "libavutil/channel_layout.h"
#include "libavutil/common.h"
#include "libavutil/cpu.h"
#include "libavutil/crc.h"
#include "libavutil/dict.h"
#include "libavutil/display.h"
#include "libavutil/downmix_info.h"
#include "libavutil/encryption_info.h"
#include "libavutil/error.h"
#include "libavutil/eval.h"
#include "libavutil/fifo.h"
#include "libavutil/file.h"
#include "libavutil/film_grain_params.h"
#include "libavutil/frame.h"
#include "libavutil/hmac.h"
#include "libavutil/hwcontext.h"
#include "libavutil/hwcontext_videotoolbox.h"
#include "libavutil/imgutils.h"
#include "libavutil/intfloat.h"
#include "libavutil/log.h"
#include "libavutil/macros.h"
#include "libavutil/mastering_display_metadata.h"
#include "libavutil/mathematics.h"
#include "libavutil/md5.h"
#include "libavutil/mem.h"
#include "libavutil/motion_vector.h"
#include "libavutil/opt.h"
#include "libavutil/parseutils.h"
#include "libavutil/pixdesc.h"
#include "libavutil/pixfmt.h"
#include "libavutil/random_seed.h"
#include "libavutil/rational.h"
#include "libavutil/replaygain.h"
#include "libavutil/samplefmt.h"
#include "libavutil/sha.h"
#include "libavutil/sha512.h"
#include "libavutil/stereo3d.h"
#include "libavutil/threadmessage.h"
#include "libavutil/time.h"
#include "libavutil/timecode.h"
#include "libavutil/timestamp.h"
#include "libavutil/uuid.h"
#include "libavutil/version.h"

// ---------------- libavcodec ----------------
#include "libavcodec/avcodec.h"
#include "libavcodec/bsf.h"
#include "libavcodec/codec.h"
#include "libavcodec/codec_desc.h"
#include "libavcodec/codec_id.h"
#include "libavcodec/codec_par.h"
#include "libavcodec/defs.h"
#include "libavcodec/packet.h"
#include "libavcodec/version.h"

// ---------------- libavformat ----------------
#include "libavformat/avformat.h"
#include "libavformat/avio.h"
#include "libavformat/version.h"

// ---------------- libswscale / libswresample ----------------
#include "libswscale/swscale.h"
#include "libswresample/swresample.h"

#endif /* METALPLAYER_FFMPEG_SHIM_H */
