# Re-testing pairing commands on new firmware

Disconnect (`0x1403`) and Forget (`0x1405`) run only on the firmware they were tested on, which is `DeviceState.testedPairingFirmware` in `Sources/M4Core/Controller/HeadphoneController.swift`. On any other firmware the app turns them off and says so under the device list. This page is how to test a new firmware and turn them back on.

> [!CAUTION]
> `0x1403` erased a pairing on firmware 2.13.42. A command that is safe on one firmware can do something else on the next, so do every step below before changing the constant in `main`.

## What you need

- The headphones on the new firmware. The popover shows the version at the bottom left.
- A spare device paired with the headphones that you do not mind pairing again, for example an old phone.
- Smart Control Plus on your phone, to confirm what the headphones did.

## Steps

1. **Open the gate on a local build only.** Set `testedPairingFirmware` to the new version and run `make install`. Do not commit yet.
2. **Watch the frames.** In Terminal run:

   ```sh
   /usr/bin/log stream --level debug --predicate 'subsystem == "com.agrmohit.momentummenu"'
   ```

   (`log` alone is a zsh builtin, so use the full path.)

3. **Disconnect.** Connect the spare device, then press its pill in the popover. Expect:
   - the spare device disconnects;
   - it is **still in the list** and still in Smart Control Plus;
   - pressing Connect brings it back.

   If it vanished from the list, the pairing was erased: stop here and put the constant back.

4. **Forget.** With the spare device not connected, right-click it, choose Forget and confirm. Expect, as on 3.38.3:

   | Step                   | 3.38.3 frames                                  |
   | ---------------------- | ---------------------------------------------- |
   | Forget sent            | `0x1405 [index]`, reply `[00]`                 |
   | Count read             | one less than before                           |
   | The emptied slot       | `0x1401` answers `[FF FF FF 00]`               |
   | Push                   | `0x1484 [index FF]`                            |

   - the device leaves the popover list within 8 seconds;
   - Smart Control Plus no longer lists it;
   - after turning the headphones off and on, the list has no gap.

5. **Check the rest.** Connect and disconnect this Mac, and switch noise modes once, to see nothing else changed.

## If everything matched

1. Change the tests that use the tested firmware as the one that passes the gate. List them with:

   ```sh
   rg -n '3, 38, 3|3\.38\.3' Tests
   ```

   They include the gate, rule and disconnect tables in `PairedDeviceTests` (and the gate test's name), the forget rows and the expected error message in `ForgetDeviceTests`, `DisconnectStateTests` and `SnapshotRender`. Keep comments that describe the 3.38.3 captures as they are.

2. Run `make check` and fix anything still failing.
3. Commit the new `testedPairingFirmware` and the tests together, with the frame log from step 4 in the commit message.
4. Update the version in the README: the "Tested firmware only" cell and the protocol notes.
5. Release as a minor version.

## If anything differed

Put the constant back, keep the gate closed, and note what the frames showed. The app stays safe as it is: on untested firmware it only turns these two actions off.
