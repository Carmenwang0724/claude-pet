import Foundation

/// Steps through the frames of one clip at a time.
struct AnimationPlayer {
    private(set) var clipName = ""
    private(set) var frameIndex = 0
    private(set) var completedCycles = 0
    private var frameElapsed: TimeInterval = 0

    /// Switches to a clip, keeping the current frame when it is already playing.
    mutating func play(_ name: String) {
        guard name != clipName else {
            return
        }
        restart(name)
    }

    /// Starts a clip from its first frame.
    mutating func restart(_ name: String) {
        clipName = name
        frameIndex = 0
        frameElapsed = 0
        completedCycles = 0
    }

    /// Moves forward by the elapsed time.
    mutating func advance(elapsed: TimeInterval, clip: AnimationClip) {
        frameIndex = min(frameIndex, clip.frameCount - 1)
        frameElapsed += elapsed
        while frameElapsed >= clip.durations[frameIndex] {
            frameElapsed -= clip.durations[frameIndex]
            frameIndex += 1
            if frameIndex >= clip.frameCount {
                frameIndex = 0
                completedCycles += 1
            }
        }
    }
}
