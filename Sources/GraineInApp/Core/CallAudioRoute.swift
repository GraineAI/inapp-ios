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
        /// Leave the route as it is: a device of the customer's own carries the call.
        case leave
    }

    /// AVAudioSession.Port raw values the customer chose by plugging in or pairing: headphones, Bluetooth, the car, USB, AirPlay, HDMI, line out.
    static let personal: Set<String> = [
        "Headphones", "BluetoothA2DPOutput", "BluetoothHFP", "BluetoothLE", "CarAudio", "USBAudio", "AirPlay", "HDMIOutput", "LineOut",
    ]

    /**
     * - Parameters:
     *   - speaker: the loudspeaker is wanted — the default, or the customer's own choice.
     *   - chosen: the customer (or the app) asked for it with `setSpeaker`; the default is not a choice.
     *   - outputs: the route's output port types now.
     */
    static func choice(speaker: Bool, chosen: Bool, outputs: [String]) -> Choice {
        // No override is the receiver, or the headset when one is in: always the way back from the loudspeaker.
        guard speaker else { return .receiver }
        let ownDevice = outputs.contains { personal.contains($0) }
        return ownDevice && !chosen ? .leave : .speaker
    }

    /// Whether the route plays out of the loudspeaker: what `speakerOn` says once the call's audio runs.
    static func onSpeaker(_ outputs: [String]) -> Bool {
        outputs.contains("Speaker")
    }
}
