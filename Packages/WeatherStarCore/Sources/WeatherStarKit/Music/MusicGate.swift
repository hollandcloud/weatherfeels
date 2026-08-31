/// Whether music should be audible right now.
///
/// Two conditions, and the second is the one that was missing: the television's power
/// button blanked the picture and left the music playing, so a set that plainly looked
/// switched off carried on making noise. Switching a television off has always meant both.
///
/// A named rule rather than an `&&` at the call site because there is more than one call
/// site — the power button, the music toggle in Settings, and coming back from the
/// background — and the bug was one of them disagreeing with the others.
public enum MusicGate {
    /// Music plays only when the user has asked for it *and* the set is on.
    ///
    /// `musicEnabled` is the user's standing preference and is deliberately not touched by
    /// standby: switching the set off must not look like switching music off, or turning it
    /// back on would leave the music silent with the setting still reading "on".
    public static func shouldPlay(musicEnabled: Bool, isSetOn: Bool) -> Bool {
        musicEnabled && isSetOn
    }
}
