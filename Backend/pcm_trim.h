#ifndef FOI_PCM_TRIM_H
#define FOI_PCM_TRIM_H

/* Main-thread PCM helper; no Core Audio, allocation, locks, I/O, or callbacks.
 * Six interleaved float channels retain FL FR FC LFE SL SR order. The caller
 * owns state and serializes requests with apply calls. Source protection is
 * unchanged: nonfinite samples or source magnitudes above 1 are rejected.
 */
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <math.h>
#include <string.h>

enum { PCM_TRIM_CHANNELS = 6, PCM_TRIM_RAMP_FRAMES = 960 };
#define PCM_TRIM_MIN_DB (-60.0)
#define PCM_TRIM_MAX_DB (6.0)

typedef struct {
    double current[PCM_TRIM_CHANNELS];
    double target[PCM_TRIM_CHANNELS];
    double step[PCM_TRIM_CHANNELS];
    double gain_db[PCM_TRIM_CHANNELS];
    uint32_t remaining[PCM_TRIM_CHANNELS];
    bool muted[PCM_TRIM_CHANNELS];
    uint64_t requested_revision;
    uint64_t completed_revision;
} PCMTrim;

typedef struct {
    uint64_t frames;
    /* Post-trim values BEFORE encoder protection, in linear sample units. */
    double peak[PCM_TRIM_CHANNELS];
    double sum_squares[PCM_TRIM_CHANNELS];
    uint64_t full_scale_samples[PCM_TRIM_CHANNELS]; /* magnitude >= 1 */
    uint64_t protected_samples[PCM_TRIM_CHANNELS];  /* magnitude > 1 */
} PCMTrimMetrics;

static inline void pcm_trim_init(PCMTrim *state) {
    memset(state, 0, sizeof(*state));
    for (unsigned channel = 0; channel < PCM_TRIM_CHANNELS; ++channel) {
        state->current[channel] = 1.0;
        state->target[channel] = 1.0;
    }
}

static inline bool pcm_trim_ramping(const PCMTrim *state) {
    for (unsigned channel = 0; channel < PCM_TRIM_CHANNELS; ++channel)
        if (state->remaining[channel]) return true;
    return false;
}

/* A request is all-or-nothing. Revision 0 is the initial unity state; callers
 * must send increasing nonzero revisions. Repeated targets do not restart an
 * in-flight ramp. Every changed target starts from the last applied gain.
 */
static inline bool pcm_trim_request(PCMTrim *state,
                                    const double gain_db[PCM_TRIM_CHANNELS],
                                    const bool muted[PCM_TRIM_CHANNELS],
                                    uint64_t revision) {
    if (!state || !gain_db || !muted || revision <= state->requested_revision)
        return false;
    double targets[PCM_TRIM_CHANNELS];
    for (unsigned channel = 0; channel < PCM_TRIM_CHANNELS; ++channel) {
        if (!isfinite(gain_db[channel]) || gain_db[channel] < PCM_TRIM_MIN_DB ||
            gain_db[channel] > PCM_TRIM_MAX_DB) return false;
        targets[channel] = muted[channel] ? 0.0 : pow(10.0, gain_db[channel] / 20.0);
    }
    for (unsigned channel = 0; channel < PCM_TRIM_CHANNELS; ++channel) {
        state->gain_db[channel] = gain_db[channel];
        state->muted[channel] = muted[channel];
        if (targets[channel] == state->target[channel]) continue;
        state->target[channel] = targets[channel];
        if (targets[channel] == state->current[channel]) {
            state->step[channel] = 0.0;
            state->remaining[channel] = 0;
        } else {
            state->step[channel] = (targets[channel] - state->current[channel]) /
                                  PCM_TRIM_RAMP_FRAMES;
            state->remaining[channel] = PCM_TRIM_RAMP_FRAMES;
        }
    }
    state->requested_revision = revision;
    if (!pcm_trim_ramping(state)) state->completed_revision = revision;
    return true;
}

/* Applies exactly frames samples/channel. The first sample of a new ramp uses
 * current + step; sample 960 reaches target exactly. Ramps continue across
 * calls. Metrics describe this call only, including values that exceeded full
 * scale before protection. Encoded PCM receives an explicit hard limit at
 * +/-1 for boosted samples; no limiting occurs at unity or below full scale.
 * A false result leaves state, samples, and metrics unchanged.
 */
static inline bool pcm_trim_apply(PCMTrim *state, float *samples, size_t frames,
                                 PCMTrimMetrics *metrics) {
    if (!state || !metrics || (frames && !samples) ||
        frames > SIZE_MAX / PCM_TRIM_CHANNELS || frames > UINT64_MAX) return false;
    const size_t count = frames * PCM_TRIM_CHANNELS;
    for (size_t index = 0; index < count; ++index)
        if (!isfinite(samples[index]) || fabsf(samples[index]) > 1.0f) return false;
    PCMTrimMetrics measured;
    memset(&measured, 0, sizeof(measured));
    measured.frames = (uint64_t)frames;
    for (size_t frame = 0; frame < frames; ++frame) {
        for (unsigned channel = 0; channel < PCM_TRIM_CHANNELS; ++channel) {
            if (state->remaining[channel]) {
                --state->remaining[channel];
                state->current[channel] = state->remaining[channel]
                    ? state->current[channel] + state->step[channel]
                    : state->target[channel];
            }
            const size_t index = frame * PCM_TRIM_CHANNELS + channel;
            const float source = samples[index];
            const double gain = state->current[channel];
            /* No float multiply at unity: preserve every source bit, including
             * signed zero and subnormals. Other gains produce float32 PCM. */
            const float trimmed = gain == 1.0 ? source : (float)((double)source * gain);
            const double magnitude = fabs((double)trimmed);
            if (magnitude > measured.peak[channel]) measured.peak[channel] = magnitude;
            measured.sum_squares[channel] += (double)trimmed * (double)trimmed;
            if (magnitude >= 1.0) ++measured.full_scale_samples[channel];
            if (magnitude > 1.0) {
                ++measured.protected_samples[channel];
                samples[index] = trimmed > 0.0f ? 1.0f : -1.0f;
            } else samples[index] = trimmed;
        }
    }
    if (!pcm_trim_ramping(state)) state->completed_revision = state->requested_revision;
    *metrics = measured;
    return true;
}

static inline double pcm_trim_rms(const PCMTrimMetrics *metrics, unsigned channel) {
    return metrics && channel < PCM_TRIM_CHANNELS && metrics->frames
        ? sqrt(metrics->sum_squares[channel] / (double)metrics->frames) : 0.0;
}

#endif
