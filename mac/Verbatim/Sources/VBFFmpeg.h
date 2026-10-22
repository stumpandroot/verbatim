// The small C layer between Swift (FFmpegAudio.swift) and the bundled audio-only FFmpeg (mac/ffmpeg/build.sh).
// It opens a file, decodes every audio track, resamples each to mono float at the rate you ask for, and hands
// back the mix of all tracks (and, when asked, each track on its own). FFmpeg's own headers stay out of this file
// so Swift sees only these few functions.
#ifndef VBFFMPEG_H
#define VBFFMPEG_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VBFFDecoder VBFFDecoder;

/// The track number `vbff_decode` passes for the mix of every track.
#define VBFF_MIX (-1)

/// Opens `path` and finds its audio tracks. Returns NULL and writes a reason into `err` when the file can't be
/// read or has no audio track FFmpeg can decode.
VBFFDecoder *vbff_open(const char *path, char *err, int errlen);
void vbff_close(VBFFDecoder *d);

/// Audio tracks this build can decode, in file order (at most 16).
int vbff_track_count(const VBFFDecoder *d);
/// The file's duration in seconds, or 0 when the container doesn't say.
double vbff_duration(const VBFFDecoder *d);
/// The track's "title" metadata ("Commentary"), or "" when there is none.
void vbff_track_title(const VBFFDecoder *d, int track, char *buf, int buflen);
/// The track's "language" metadata as the file gives it (usually ISO 639-2, such as "eng"), or "".
void vbff_track_language(const VBFFDecoder *d, int track, char *buf, int buflen);
/// The codec's short name ("aac", "opus"), for the log.
void vbff_track_codec(const VBFFDecoder *d, int track, char *buf, int buflen);

/// Mono float samples at the requested rate: `track` is VBFF_MIX for the mix of every track, or 0…n-1 for one
/// track (only when `separate` is nonzero). Return nonzero to stop decoding.
typedef int (*vbff_samples_fn)(void *ctx, int track, const float *samples, int count);
/// 0…1 through the file, at most once per whole percent. Return nonzero to stop decoding.
typedef int (*vbff_progress_fn)(void *ctx, double fraction);

/// Decodes every audio track once, start to end, in constant memory. Tracks that start late are placed at their
/// start time; the mix is limited softly so it never clips. Returns 0 when finished, 1 when a callback stopped it,
/// and a negative number with a reason in `err` when nothing could be decoded.
int vbff_decode(VBFFDecoder *d, int sample_rate, int separate, void *ctx,
                vbff_samples_fn on_samples, vbff_progress_fn on_progress, char *err, int errlen);

/// FFmpeg's version ("7.1.5"), the configure options the linked libraries were built with, and their license.
const char *vbff_version(void);
const char *vbff_configuration(void);
const char *vbff_license(void);

#ifdef __cplusplus
}
#endif

#endif
