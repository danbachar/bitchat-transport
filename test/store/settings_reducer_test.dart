import 'package:flutter_test/flutter_test.dart';
import 'package:bitchat_transport/src/store/settings_state.dart';
import 'package:bitchat_transport/src/store/settings_actions.dart';
import 'package:bitchat_transport/src/store/settings_reducer.dart';

/// A non-settings action used to verify the reducer ignores unknown actions.
class _UnknownAction extends SettingsAction {}

void main() {
  group('settingsReducer', () {
    group('default state', () {
      test('initial state has bluetoothEnabled=true and irohEnabled=true',
          () {
        const state = SettingsState.initial;

        expect(state.bluetoothEnabled, isTrue);
        expect(state.irohEnabled, isTrue);
        expect(state.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.iroh,
        ]);
      });

      test('unknown action returns the same state unchanged', () {
        const state = SettingsState.initial;
        final result = settingsReducer(state, _UnknownAction());

        expect(result, same(state));
      });
    });

    group('SetBluetoothEnabledAction', () {
      test('sets bluetoothEnabled to true', () {
        const state = SettingsState(bluetoothEnabled: false);
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(true),
        );

        expect(result.bluetoothEnabled, isTrue);
      });

      test('sets bluetoothEnabled to false', () {
        const state = SettingsState(bluetoothEnabled: true);
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(false),
        );

        expect(result.bluetoothEnabled, isFalse);
      });

      test('preserves irohEnabled and transportPriority', () {
        const state = SettingsState(
          bluetoothEnabled: true,
          irohEnabled: false,
          transportPriority: [TransportProtocol.iroh],
        );
        final result = settingsReducer(
          state,
          SetBluetoothEnabledAction(false),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.irohEnabled, isFalse);
        expect(result.transportPriority, [TransportProtocol.iroh]);
      });
    });

    group('SetIrohEnabledAction', () {
      test('sets irohEnabled to true', () {
        const state = SettingsState(irohEnabled: false);
        final result = settingsReducer(
          state,
          SetIrohEnabledAction(true),
        );

        expect(result.irohEnabled, isTrue);
      });

      test('sets irohEnabled to false', () {
        const state = SettingsState(irohEnabled: true);
        final result = settingsReducer(
          state,
          SetIrohEnabledAction(false),
        );

        expect(result.irohEnabled, isFalse);
      });

      test('preserves bluetoothEnabled and transportPriority', () {
        const state = SettingsState(
          bluetoothEnabled: false,
          irohEnabled: true,
          transportPriority: [
            TransportProtocol.iroh,
            TransportProtocol.bluetooth,
          ],
        );
        final result = settingsReducer(
          state,
          SetIrohEnabledAction(false),
        );

        expect(result.irohEnabled, isFalse);
        expect(result.bluetoothEnabled, isFalse);
        expect(result.transportPriority, [
          TransportProtocol.iroh,
          TransportProtocol.bluetooth,
        ]);
      });
    });

    group('UpdateTransportSettingsAction', () {
      test('updates multiple settings at once', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            bluetoothEnabled: false,
            irohEnabled: false,
          ),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.irohEnabled, isFalse);
        // transportPriority not provided, so it should remain at default
        expect(result.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.iroh,
        ]);
      });

      test('can change transport priority order', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            transportPriority: [
              TransportProtocol.iroh,
              TransportProtocol.bluetooth,
            ],
          ),
        );

        expect(result.transportPriority, [
          TransportProtocol.iroh,
          TransportProtocol.bluetooth,
        ]);
        // Fields not provided in the action should remain unchanged
        expect(result.bluetoothEnabled, isTrue);
        expect(result.irohEnabled, isTrue);
      });

      test('updates all fields simultaneously', () {
        const state = SettingsState.initial;
        final result = settingsReducer(
          state,
          UpdateTransportSettingsAction(
            bluetoothEnabled: false,
            irohEnabled: true,
            transportPriority: [TransportProtocol.iroh],
          ),
        );

        expect(result.bluetoothEnabled, isFalse);
        expect(result.irohEnabled, isTrue);
        expect(result.transportPriority, [TransportProtocol.iroh]);
      });
    });

    group('HydrateSettingsAction', () {
      test('replaces entire settings state', () {
        const state = SettingsState.initial;
        const hydratedState = SettingsState(
          bluetoothEnabled: false,
          irohEnabled: false,
        );
        final result = settingsReducer(
          state,
          HydrateSettingsAction(hydratedState),
        );

        expect(result, equals(hydratedState));
        expect(result.bluetoothEnabled, isFalse);
        expect(result.irohEnabled, isFalse);
      });

      test('handles custom transport priority', () {
        const state = SettingsState.initial;
        const hydratedState = SettingsState(
          bluetoothEnabled: true,
          irohEnabled: false,
          transportPriority: [
            TransportProtocol.iroh,
            TransportProtocol.bluetooth,
          ],
        );
        final result = settingsReducer(
          state,
          HydrateSettingsAction(hydratedState),
        );

        expect(result.transportPriority, [
          TransportProtocol.iroh,
          TransportProtocol.bluetooth,
        ]);
        expect(result.bluetoothEnabled, isTrue);
        expect(result.irohEnabled, isFalse);
      });

      test('completely discards previous state', () {
        const previousState = SettingsState(
          bluetoothEnabled: false,
          irohEnabled: false,
          transportPriority: [TransportProtocol.iroh],
        );
        const hydratedState = SettingsState(
          bluetoothEnabled: true,
          irohEnabled: true,
          transportPriority: [
            TransportProtocol.bluetooth,
            TransportProtocol.iroh,
          ],
        );
        final result = settingsReducer(
          previousState,
          HydrateSettingsAction(hydratedState),
        );

        expect(result, equals(hydratedState));
        expect(result.bluetoothEnabled, isTrue);
        expect(result.irohEnabled, isTrue);
        expect(result.transportPriority, [
          TransportProtocol.bluetooth,
          TransportProtocol.iroh,
        ]);
      });
    });
  });
}
