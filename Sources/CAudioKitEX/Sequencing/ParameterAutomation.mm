// Copyright AudioKit. All Rights Reserved. Revision History at http://github.com/AudioKit/AudioKit/

#include "ParameterAutomation.h"
#include <algorithm>
#include <mach/mach_time.h>
#include <map>
#include <vector>
#include <list>
#include <utility>

/// Returns a render observer block which will apply the automation to the selected parameter.
extern "C"
AURenderObserver ParameterAutomationGetRenderObserver(AUParameterAddress address,
                                                      AUScheduleParameterBlock scheduleParameterBlock,
                                                      double sampleRate,
                                                      double startSampleTime,
                                                      const struct AutomationEvent* eventsArray,
                                                      size_t count) {

    std::vector<AutomationEvent> events{eventsArray, eventsArray+count};

    // Sort events by start time.
    std::sort(events.begin(), events.end(), [](auto a, auto b) {
        return a.startTime < b.startTime;
    });

    __block int index = 0;

    return ^void(AudioUnitRenderActionFlags actionFlags,
                 const AudioTimeStamp *timestamp,
                 AUAudioFrameCount frameCount,
                 NSInteger outputBusNumber)
    {
        if (actionFlags != kAudioUnitRenderAction_PreRender) return;

        double blockStartSample = timestamp->mSampleTime - startSampleTime;
        double blockEndSample = blockStartSample + frameCount;

        AUValue initial = NAN;

        // Skip over events completely in the past to determine
        // an initial value.
        for (; index < count; ++index) {
            auto event = events[index];
            double eventStartSample = event.startTime * sampleRate;
            double rampSampleDuration = event.rampDuration * sampleRate;
            double eventEndSample = eventStartSample + rampSampleDuration;
            if (eventEndSample >= blockStartSample) {
                break;
            }
            initial = event.targetValue;
        }
        //NSLog(@"[x]Render: %f - %f [Initial: %f][%d]", blockStartSample, blockEndSample, initial, index);

        // Do we have an initial value from completed events?
        if (!isnan(initial)) {
            //NSLog(@"[x]Schedule [IMMEDIATE][%f]", initial);
            scheduleParameterBlock(AUEventSampleTimeImmediate,
                                   0,
                                   address,
                                   initial);
        }

        // Apply parameter automation for the segment.
        while (index < count) {
            auto event = events[index];
            double eventStartSample = event.startTime * sampleRate;
            double eventEndSample = eventStartSample + event.rampDuration * sampleRate;

            // Is it after the current block?
            if (eventStartSample >= blockEndSample) {
                break;
            }

            //NSLog(@"[x][%d] Event: %f | %f | %f", index, event.startTime, event.rampDuration, event.targetValue);
            AUEventSampleTime startTime = eventStartSample - blockStartSample;
            AUAudioFrameCount duration = event.rampDuration * sampleRate;

            // If the event has already started, ensure we hit the targetValue
            // at the appropriate time.
            if (startTime < 0) {
                duration += startTime;
                
                /// Michał change   /////////////////////////////////////////////////////////////////////
                // Ramp has started in the past so interpolate
                // what value we should start from now.
                float startValue;
                if (index - 1 >= 0) {
                    startValue = events[index - 1].targetValue;
                } else {
                    startValue = isnan(initial) ? 1.0 : initial;
                }
                float a = event.rampDuration > 0 ? (event.targetValue - startValue) / event.rampDuration : 0.0;
                float x = abs(startTime / sampleRate);
                float volume = x * a + startValue;
                
                //NSLog(@"[x] Schedule[B] [IMMEDIATE][%f]", volume);
                scheduleParameterBlock(AUEventSampleTimeImmediate,
                                       0,
                                       address,
                                       volume);
                
                // startTime can't be negative so change to 'immediate'.
                startTime = AUEventSampleTimeImmediate;
                //////////////////////////////////////////////////////////////////////////////////////////////////
            }

            //NSLog(@"[x][%d]Schedule[A] [Start: %lld][Dur: %u][%f]", index, startTime, duration, event.targetValue);
            scheduleParameterBlock(startTime,
                                   duration,
                                   address,
                                   event.targetValue);

//            index++;
            if (eventEndSample <= blockEndSample) {
                index++;
                //NSLog(@"[x] Increased index to %d", index);
            } else {
                break;
            }
        }

    };

}
