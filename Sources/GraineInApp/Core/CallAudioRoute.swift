import Foundation

/**
 * WHERE A NATIVE CALL'S VOICE COMES OUT — the loudspeaker by default
 * (`GraineCalls.speakerByDefault`): a call the customer holds away from the
 * ear, as the in-app Talk does, rather than a phone call's earpiece they may
 * never raise. Never pulled off a route that is the customer's own — a wired
 * or Bluetooth headset, a car, AirPlay — unless they ask for the speaker
 * themselves (`setSpeaker(true)`). `setSpeaker(false)` is the earpiece.
 * Pure, on AVAudioSession's port names, so a Mac proves it.
 */
enum CallAudioRoute {
    enum Choice: Equatable {
        /// Override the output to the loudspeaker.
        case speaker
        /// No override: the receiver — or the customer's own device, when one is the route.
        case receiver
        /// A device of the customer's own carries the call, or is about to: no override (a default one is lifted).
        case leave
    }

    /// AVAudioSession.Port raw values the customer chose by plugging in or pairing: headphones, Bluetooth, the car, USB, AirPlay, HDMI, line out.
    static let personal: Set<String> = [
        "Headphones", "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE", "CarAudio", "USBAudio", "AirPlay", "HDMIOutput", "LineOut",
    ]

    /// AVAudioSession.Port raw values of a microphone the customer brought: a wired headset's, a Bluetooth headset's or car kit's, the car's, USB.
    static let personalInputs: Set<String> = ["MicrophoneWired", "BluetoothHFP", "BluetoothLE", "CarAudio", "USBAudio"]

    /**
     * - Parameters:
     *   - speaker: the loudspeaker is wanted — the default, or the customer's own choice.
     *   - chosen: the customer (or the app) asked for it with `setSpeaker`; the default is not a choice.
     *   - outputs: the route's output port types now.
     *   - inputs: the session's available input port types. A Bluetooth headset that is connected is listed
     *     here at once, while its hands-free link — the output — comes up a moment after the call's audio:
     *     the default must not take the call to the loudspeaker in that moment, and a default loudspeaker
     *     already set is lifted (`leave` removes the override) so the headset takes the call.
     */
    static func choice(speaker: Bool, chosen: Bool, outputs: [String], inputs: [String] = []) -> Choice {
        // No override is the receiver, or the headset when one is in: always the way back from the loudspeaker.
        guard speaker else { return .receiver }
        if chosen { return .speaker }
        let ownDevice = outputs.contains { personal.contains($0) } || inputs.contains { personalInputs.contains($0) }
        return ownDevice ? .leave : .speaker
    }

    /// Whether the route plays out of the loudspeaker: what `speakerOn` says once the call's audio runs.
    static func onSpeaker(_ outputs: [String]) -> Bool {
        outputs.contains("Speaker")
    }
}
