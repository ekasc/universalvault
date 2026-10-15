# Compatibility

Inserted via AX `kAXSelectedTextAttribute` and CGEvent fallback. Test matrix not yet executed end-to-end in this build. Expected support: TextEdit, Notes, native SwiftUI/AppKit fields, Safari/Chrome HTML inputs. Workday not specially handled. Known limitations: browser origin cannot be proven; critical fields require reauthentication (not domain allowlists). Automated tests cover domain/crypto only; UI/insertion tests require interactive manual verification with granted Accessibility permission.
