// See VBFFmpeg.h. Links against the bundled LGPL FFmpeg frameworks (mac/ffmpeg/build.sh).
#include "VBFFmpeg.h"

#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/avutil.h>
#include <libavutil/channel_layout.h>
#include <libavutil/opt.h>
#include <libswresample/swresample.h>

#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define VBFF_MAX_TRACKS 16
/// A track this far behind the furthest one is treated as ended (or not started) so the mix keeps moving.
#define VBFF_STALL_SECONDS 30
/// Leading silence for a late track is capped here; anything later is a timestamp problem, not a real offset.
#define VBFF_MAX_OFFSET_SECONDS 600

typedef struct {
    int stream_index;
    AVCodecContext *cc;
    SwrContext *swr;
    int in_rate;
    int in_format;
    AVChannelLayout in_layout;
    float *buf;
    int bufcap;
    int started;
    long long cursor;   // where this track's next sample goes, in output samples from the file's start
} VBFFTrack;

struct VBFFDecoder {
    AVFormatContext *fmt;
    VBFFTrack tracks[VBFF_MAX_TRACKS];
    int n;
};

static void put(char *buf, int len, const char *s) {
    if (!buf || len <= 0) return;
    snprintf(buf, (size_t)len, "%s", s ? s : "");
}

static void put_averror(char *buf, int len, const char *what, int code) {
    char e[128];
    av_strerror(code, e, sizeof e);
    if (buf && len > 0) snprintf(buf, (size_t)len, "%s: %s", what, e);
}

VBFFDecoder *vbff_open(const char *path, char *err, int errlen) {
    VBFFDecoder *d = calloc(1, sizeof *d);
    if (!d) { put(err, errlen, "out of memory"); return NULL; }
    int r = avformat_open_input(&d->fmt, path, NULL, NULL);
    if (r < 0) { put_averror(err, errlen, "couldn't open the file", r); free(d); return NULL; }
    r = avformat_find_stream_info(d->fmt, NULL);
    if (r < 0) { put_averror(err, errlen, "couldn't read the file's streams", r); vbff_close(d); return NULL; }
    for (unsigned i = 0; i < d->fmt->nb_streams; i++) {
        AVStream *st = d->fmt->streams[i];
        st->discard = AVDISCARD_ALL;
        if (st->codecpar->codec_type != AVMEDIA_TYPE_AUDIO || d->n >= VBFF_MAX_TRACKS) continue;
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (!codec) continue;
        AVCodecContext *cc = avcodec_alloc_context3(codec);
        if (!cc) continue;
        if (avcodec_parameters_to_context(cc, st->codecpar) < 0 || (cc->pkt_timebase = st->time_base, avcodec_open2(cc, codec, NULL) < 0)) {
            avcodec_free_context(&cc);
            continue;
        }
        VBFFTrack *t = &d->tracks[d->n++];
        memset(t, 0, sizeof *t);
        t->stream_index = (int)i;
        t->cc = cc;
        t->in_format = -1;
        st->discard = AVDISCARD_DEFAULT;
    }
    if (d->n == 0) { put(err, errlen, "no audio track this build can decode"); vbff_close(d); return NULL; }
    return d;
}

void vbff_close(VBFFDecoder *d) {
    if (!d) return;
    for (int i = 0; i < d->n; i++) {
        VBFFTrack *t = &d->tracks[i];
        avcodec_free_context(&t->cc);
        swr_free(&t->swr);
        av_channel_layout_uninit(&t->in_layout);
        free(t->buf);
    }
    if (d->fmt) avformat_close_input(&d->fmt);
    free(d);
}

int vbff_track_count(const VBFFDecoder *d) { return d ? d->n : 0; }

double vbff_duration(const VBFFDecoder *d) {
    if (!d || !d->fmt || d->fmt->duration == AV_NOPTS_VALUE || d->fmt->duration <= 0) return 0;
    return (double)d->fmt->duration / AV_TIME_BASE;
}

static const char *meta(const VBFFDecoder *d, int track, const char *key) {
    if (!d || track < 0 || track >= d->n) return "";
    AVDictionaryEntry *e = av_dict_get(d->fmt->streams[d->tracks[track].stream_index]->metadata, key, NULL, 0);
    return e && e->value ? e->value : "";
}

void vbff_track_title(const VBFFDecoder *d, int track, char *buf, int buflen) { put(buf, buflen, meta(d, track, "title")); }
void vbff_track_language(const VBFFDecoder *d, int track, char *buf, int buflen) { put(buf, buflen, meta(d, track, "language")); }
void vbff_track_codec(const VBFFDecoder *d, int track, char *buf, int buflen) {
    put(buf, buflen, (d && track >= 0 && track < d->n) ? avcodec_get_name(d->tracks[track].cc->codec_id) : "");
}

const char *vbff_version(void) { return av_version_info(); }
const char *vbff_configuration(void) { return avformat_configuration(); }
const char *vbff_license(void) { return avformat_license(); }

// MARK: Decoding

typedef struct {
    VBFFDecoder *d;
    int rate;
    int separate;
    void *ctx;
    vbff_samples_fn on_samples;
    int stopped;
    long long produced;      // samples handed to the mix
    // The mix: samples from absolute position `mix_base` for `mix_len` samples.
    float *mix;
    long long mix_base;
    int mix_len;
    int mix_cap;
    float zeros[4096];
} VBFFRun;

/// Unity below 0.8, then a soft knee that never passes 1 (MultitrackAudio.limit).
static float limit(float x) {
    float a = fabsf(x);
    if (a <= 0.8f) return x;
    float y = 0.8f + 0.2f * tanhf((a - 0.8f) / 0.2f);
    return x < 0 ? -y : y;
}

static void emit(VBFFRun *r, int track, const float *s, int n) {
    while (n > 0 && !r->stopped) {
        int k = n > 65536 ? 65536 : n;
        if (r->on_samples(r->ctx, track, s, k)) r->stopped = 1;
        s += k; n -= k;
    }
}

static void emit_zeros(VBFFRun *r, int track, long long n) {
    while (n > 0 && !r->stopped) {
        int k = n > 4096 ? 4096 : (int)n;
        if (r->on_samples(r->ctx, track, r->zeros, k)) r->stopped = 1;
        n -= k;
    }
}

static int mix_reserve(VBFFRun *r, int len) {
    if (len <= r->mix_cap) return 1;
    int cap = r->mix_cap ? r->mix_cap : 65536;
    while (cap < len) cap *= 2;
    float *m = realloc(r->mix, (size_t)cap * sizeof(float));
    if (!m) return 0;
    r->mix = m; r->mix_cap = cap;
    return 1;
}

static void mix_add(VBFFRun *r, long long at, const float *s, int n) {
    if (at < r->mix_base) {   // arrived after that stretch was already written: drop the overlap
        long long skip = r->mix_base - at;
        if (skip >= n) return;
        s += skip; n -= (int)skip; at = r->mix_base;
    }
    long long end = at + n - r->mix_base;
    if (end > r->mix_len) {
        if (end > 0x7fffffff || !mix_reserve(r, (int)end)) { r->stopped = 1; return; }
        memset(r->mix + r->mix_len, 0, (size_t)(end - r->mix_len) * sizeof(float));
        r->mix_len = (int)end;
    }
    float *m = r->mix + (at - r->mix_base);
    for (int i = 0; i < n; i++) m[i] += s[i];
}

/// Writes out the mix up to the point every live track has reached (everything, at the end).
static void mix_flush(VBFFRun *r, int all) {
    long long upto = r->mix_base + r->mix_len;
    if (!all) {
        long long furthest = 0;
        for (int i = 0; i < r->d->n; i++) if (r->d->tracks[i].cursor > furthest) furthest = r->d->tracks[i].cursor;
        long long stall = (long long)VBFF_STALL_SECONDS * r->rate;
        for (int i = 0; i < r->d->n; i++) {
            VBFFTrack *t = &r->d->tracks[i];
            long long at = t->started ? t->cursor : 0;
            if (furthest - at > stall) continue;   // ended early, or hasn't started: don't wait for it
            if (at < upto) upto = at;
        }
    }
    int n = (int)(upto - r->mix_base);
    if (n <= 0) return;
    if (n > r->mix_len) n = r->mix_len;
    for (int i = 0; i < n; i++) r->mix[i] = limit(r->mix[i]);
    emit(r, VBFF_MIX, r->mix, n);
    memmove(r->mix, r->mix + n, (size_t)(r->mix_len - n) * sizeof(float));
    r->mix_len -= n;
    r->mix_base += n;
}

static void deliver(VBFFRun *r, int ti, const float *s, int n) {
    VBFFTrack *t = &r->d->tracks[ti];
    if (n <= 0) return;
    if (r->separate) emit(r, ti, s, n);
    mix_add(r, t->cursor, s, n);
    t->cursor += n;
    r->produced += n;
    mix_flush(r, 0);
}

static int ensure_buf(VBFFTrack *t, int n) {
    if (n <= t->bufcap) return 1;
    float *b = realloc(t->buf, (size_t)n * sizeof(float));
    if (!b) return 0;
    t->buf = b; t->bufcap = n;
    return 1;
}

/// (Re)builds the track's resampler when the decoded format changes.
static int ensure_swr(VBFFRun *r, VBFFTrack *t, const AVFrame *f) {
    AVChannelLayout in = {0};
    if (f->ch_layout.order == AV_CHANNEL_ORDER_UNSPEC || f->ch_layout.nb_channels <= 0) {
        av_channel_layout_default(&in, f->ch_layout.nb_channels > 0 ? f->ch_layout.nb_channels : 1);
    } else if (av_channel_layout_copy(&in, &f->ch_layout) < 0) {
        return 0;
    }
    if (t->swr && t->in_rate == f->sample_rate && t->in_format == f->format && av_channel_layout_compare(&t->in_layout, &in) == 0) {
        av_channel_layout_uninit(&in);
        return 1;
    }
    swr_free(&t->swr);
    AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
    if (swr_alloc_set_opts2(&t->swr, &mono, AV_SAMPLE_FMT_FLT, r->rate, &in, (enum AVSampleFormat)f->format, f->sample_rate, 0, NULL) < 0
        || swr_init(t->swr) < 0) {
        swr_free(&t->swr);
        av_channel_layout_uninit(&in);
        return 0;
    }
    av_channel_layout_uninit(&t->in_layout);
    t->in_layout = in;
    t->in_rate = f->sample_rate;
    t->in_format = f->format;
    return 1;
}

static void place_start(VBFFRun *r, int ti, const AVFrame *f) {
    VBFFTrack *t = &r->d->tracks[ti];
    t->started = 1;
    long long offset = 0;
    if (r->d->n > 1 && f->best_effort_timestamp != AV_NOPTS_VALUE) {
        AVStream *st = r->d->fmt->streams[t->stream_index];
        double start = r->d->fmt->start_time != AV_NOPTS_VALUE ? (double)r->d->fmt->start_time / AV_TIME_BASE : 0;
        double secs = (double)f->best_effort_timestamp * av_q2d(st->time_base) - start;
        if (secs > 0.01 && secs < VBFF_MAX_OFFSET_SECONDS) offset = llround(secs * r->rate);
    }
    t->cursor = offset;
    if (r->separate && offset > 0) emit_zeros(r, ti, offset);
}

static void convert(VBFFRun *r, int ti, const AVFrame *f) {
    VBFFTrack *t = &r->d->tracks[ti];
    if (f) {
        if (f->nb_samples <= 0 || f->sample_rate <= 0 || !ensure_swr(r, t, f)) return;
        if (!t->started) place_start(r, ti, f);
    } else if (!t->swr) {
        return;
    }
    int want = swr_get_out_samples(t->swr, f ? f->nb_samples : 0) + 256;
    if (want < 1024) want = 1024;
    if (!ensure_buf(t, want)) { r->stopped = 1; return; }
    for (;;) {
        uint8_t *out = (uint8_t *)t->buf;
        int got = f ? swr_convert(t->swr, &out, t->bufcap, (const uint8_t **)f->extended_data, f->nb_samples)
                    : swr_convert(t->swr, &out, t->bufcap, NULL, 0);
        if (got <= 0) break;
        deliver(r, ti, t->buf, got);
        if (f || r->stopped) break;   // a frame converts in one call; a flush loops until the resampler is empty
    }
}

static void drain(VBFFRun *r, int ti, AVFrame *frame) {
    VBFFTrack *t = &r->d->tracks[ti];
    while (!r->stopped && avcodec_receive_frame(t->cc, frame) == 0) {
        convert(r, ti, frame);
        av_frame_unref(frame);
    }
}

int vbff_decode(VBFFDecoder *d, int sample_rate, int separate, void *ctx,
                vbff_samples_fn on_samples, vbff_progress_fn on_progress, char *err, int errlen) {
    if (!d || !on_samples || sample_rate <= 0) { put(err, errlen, "bad arguments"); return -1; }
    VBFFRun *r = calloc(1, sizeof *r);
    AVPacket *pkt = av_packet_alloc();
    AVFrame *frame = av_frame_alloc();
    if (!r || !pkt || !frame) { free(r); av_packet_free(&pkt); av_frame_free(&frame); put(err, errlen, "out of memory"); return -1; }
    r->d = d; r->rate = sample_rate; r->separate = separate; r->ctx = ctx; r->on_samples = on_samples;

    int index_of[1024];
    for (int i = 0; i < 1024; i++) index_of[i] = -1;
    for (int i = 0; i < d->n; i++) if (d->tracks[i].stream_index < 1024) index_of[d->tracks[i].stream_index] = i;

    double duration = vbff_duration(d);
    double start = d->fmt->start_time != AV_NOPTS_VALUE ? (double)d->fmt->start_time / AV_TIME_BASE : 0;
    int last_percent = -1;
    int rr;
    while (!r->stopped && (rr = av_read_frame(d->fmt, pkt)) >= 0) {
        int ti = (pkt->stream_index >= 0 && pkt->stream_index < 1024) ? index_of[pkt->stream_index] : -1;
        if (ti < 0) { av_packet_unref(pkt); continue; }
        if (on_progress && duration > 0 && pkt->pts != AV_NOPTS_VALUE) {
            double at = (double)pkt->pts * av_q2d(d->fmt->streams[pkt->stream_index]->time_base) - start;
            int percent = (int)(at / duration * 100);
            if (percent > 100) percent = 100;
            if (percent > last_percent) {
                last_percent = percent;
                if (on_progress(ctx, percent / 100.0)) r->stopped = 1;
            }
        }
        // A damaged packet is skipped; the rest of the file still decodes.
        if (avcodec_send_packet(d->tracks[ti].cc, pkt) >= 0) drain(r, ti, frame);
        av_packet_unref(pkt);
    }
    // The end (or a damaged tail): flush each decoder and resampler, then the rest of the mix.
    for (int i = 0; i < d->n && !r->stopped; i++) {
        if (avcodec_send_packet(d->tracks[i].cc, NULL) >= 0) drain(r, i, frame);
        convert(r, i, NULL);
    }
    if (!r->stopped) mix_flush(r, 1);

    int result = 0;
    if (r->stopped) result = 1;
    else if (r->produced == 0) { put(err, errlen, "no audio could be decoded"); result = -2; }
    free(r->mix);
    free(r);
    av_packet_free(&pkt);
    av_frame_free(&frame);
    return result;
}
