//
//  Ear.swift
//  Digital Ear
//
//  Created by Alex Reidy on 3/7/15.
//  Copyright (c) 2015 Alex Reidy. All rights reserved.
//

import Foundation
import AVFoundation

class Ear: NSObject, AVAudioRecorderDelegate {
    
    private let audioSession = AVAudioSession()
    
    private var recorder: AVAudioRecorder!
    
    let settings = defaultAudioSettings
    
    private var onSoundRecognized: (soundName: String) -> ()
    
    private var shouldStopRecording = false
    
    private var sounds: [Sound] = []
        
    init(onSoundRecognized: (soundName: String) -> (), sampleRate: Int) {
        self.onSoundRecognized = onSoundRecognized
        
        audioSession.setCategory(AVAudioSessionCategoryRecord, error: nil)
        audioSession.setMode(AVAudioSessionModeMeasurement, error: nil)
        audioSession.setActive(true, error: nil)
        
        settings[AVSampleRateKey] = sampleRate
        
    }
    
    class func adjustForNoiseAndTrimEnds(samples: [Float]) -> [Float] {
        // At low amplitudes, the fluctuation across "zero" due to noise
        // is actually quite pronounced, resulting in high frequencies when
        // it's quiet, so we just change all of the negligibly small amplitudes to zero.
        // Additionally, we remove any leading or trailing zeros before returning.
        
        var noiseAdjustedSamples = samples
        var firstNonzeroAmplitudeIndex = 0, lastNonzeroAmplitudeIndex = 0
        for var i = 0; i < samples.count; i++ {
            if abs(samples[i]) < 0.001 {
                noiseAdjustedSamples[i] = 0.0
            } else { // => amp is nontrivial
                lastNonzeroAmplitudeIndex = i
                if firstNonzeroAmplitudeIndex == 0 {
                    firstNonzeroAmplitudeIndex = i
                }
            }
        }
        return Array(noiseAdjustedSamples[
            firstNonzeroAmplitudeIndex..<lastNonzeroAmplitudeIndex+1])
    }
    
    class func countCyclesIn(samples: [Float]) -> Int {
        if samples.count == 0 { return 0 }
        
        var zeroCrossings = 0
        var prevSign = sign(samples[0])
        
        for amplitude in samples {
            var currentSign = sign(amplitude)
            if currentSign == -prevSign {
                zeroCrossings++
            }
            prevSign = currentSign
        }
        
        return Int(round(Float(zeroCrossings) / 2.0))
    }
    
    class func countFrequencyIn(samples: [Float], sampleRate: Int) -> Float {
        let cycles = countCyclesIn(samples)
        let seconds: Float = Float(samples.count) / Float(sampleRate)
        return Float(cycles) / seconds
    }
    
    private func createFrequencyArray(samples: [Float], sampleRate: Int, freqChunksPerSec: Int = 20) -> [Float] {
        // TODO - redo with slices for performance
        
        let samplesPerChunk = sampleRate / freqChunksPerSec
        if samples.count < samplesPerChunk {
            // In this case, would return [] without the explicit
            // statement, but this saves some CPU cycles
            return []
        }
        
        var freqArray: [Float] = []
        var samplesForChunk = [Float](count: samplesPerChunk, repeatedValue: 0.0)
        
        for var n = 0, i = 0; n < samples.count; n++, i++ {
            if i == samplesForChunk.count {
                freqArray.append(Ear.countFrequencyIn(samplesForChunk, sampleRate: sampleRate))
                i = 0
                continue
            }
            
            samplesForChunk[i] = samples[n]
        }
        
        return freqArray
    }
    
    private func calcAverageRelativeFreqDiff(freqListA: [Float], freqListB: [Float]) -> Float {
        // We "slide" the smaller freqList across the larger one and compare each frequency
        // to compute the minimum average relative difference in frequency (a proportion)
        
        var largeFreqList: [Float] = freqListB
        var smallFreqList: [Float] = freqListA
        if freqListA.count > freqListB.count {
            largeFreqList = freqListA
            smallFreqList = freqListB
        }
        
        if freqListA.count == 0 && freqListB.count == 0 {
            return 0
        }
        if smallFreqList.count == 0 {
            // NO frequency can't be similar to SOME frequencies
            return 1
        }
        // Notice that this point reached => smallFreqList is not empty
        if largeFreqList.count == 0 {
            return 1
        }
        
        let freqListLenDiff = largeFreqList.count - smallFreqList.count
        var minAvgRelativeFreqDiff: Float = 1

        for (var indexOffset = 0; indexOffset <= freqListLenDiff; indexOffset++) {
            var relativeFreqDiffSum: Float = 0
            for (var i = 0; i < smallFreqList.count; i++) {
                let base: Float = max(smallFreqList[i], largeFreqList[i + indexOffset])
                if base > 0 {
                    relativeFreqDiffSum += abs(smallFreqList[i] - largeFreqList[i + indexOffset]) / base
                }
            }
            
            let avgRelativeFreqDiff = relativeFreqDiffSum / Float(smallFreqList.count)
            
            if avgRelativeFreqDiff < minAvgRelativeFreqDiff {
                minAvgRelativeFreqDiff = avgRelativeFreqDiff
            }
        }
        
        return minAvgRelativeFreqDiff
    }
    
    func audioRecorderDidFinishRecording(recorder: AVAudioRecorder!, successfully flag: Bool) {
        if shouldStopRecording { return }
        println("finished recording; processing...")
        var samplesInQuestion = Ear.adjustForNoiseAndTrimEnds(
            extractSamplesFromWAV(NSTemporaryDirectory()+"tmp.wav"))
        
        for sound in sounds {
            println(sound.name)
            for rec in sound.recordings {
                let fileName = rec.valueForKey("fileName") as String
                var samplesInSavedRecording = Ear.adjustForNoiseAndTrimEnds(
                    extractSamplesFromWAV(DOCUMENT_DIR+"\(fileName).wav"))
                
                let freqListA = createFrequencyArray(samplesInQuestion, sampleRate: DEFAULT_SAMPLE_RATE)
                let freqListB = createFrequencyArray(samplesInSavedRecording, sampleRate: DEFAULT_SAMPLE_RATE)
                
                let averageFreqDiff = calcAverageRelativeFreqDiff(freqListA, freqListB: freqListB)
                println(averageFreqDiff)
                if averageFreqDiff < 0.30 {
                    onSoundRecognized(soundName: sound.name)
                    // Sound has been recognized, so we don't analyze any more of its recordings
                    break
                }
            }
        }
        
        listen() // potential call stack issues with this recursion?
    }
    
    private func recordAudio(toPath path: String, seconds: Double) {
        recorder = AVAudioRecorder(URL: NSURL(fileURLWithPath: path),
            settings: settings, error: nil)
        recorder.delegate = self
        recorder.recordForDuration(seconds)
    }
    
    func listen() {
        println("going to record")
        shouldStopRecording = false
        
        sounds = getSounds()
        
        recordAudio(toPath: NSTemporaryDirectory()+"tmp.wav", seconds: 5)
    }
    
    func stop() {
        println("done recording")
        shouldStopRecording = true
        stopRecordingAudio()
    }

}