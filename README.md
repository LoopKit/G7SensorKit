# G7SensorKit

A Loop plugin for the Dexcom G7, ONE+ and Stelo sensors.

The plugin connects to the sensor directly over Bluetooth. Pair it with the 4-digit code printed on the sensor applicator (typed or scanned), and readings, backfill, sensor status and lifecycle alerts come straight from the sensor. The Dexcom app is not needed, and must not be installed alongside: a sensor admits one display at a time.

For a sensor already in use with the Dexcom app whose code is not available, the plugin can instead read alongside the Dexcom app's own session until the next sensor is paired directly.

## Features

- Direct pairing and session management for G7, ONE+ and Stelo, including 15-day sensors
- Sensor application guide and pairing flow
- Gap backfill after any time out of range
- Lifecycle alerts: sensor expiring, expired, session ended, sensor failed, signal loss, connection refused
- Calibration, with guidance on when it is appropriate
- Sensor details in settings: model, serial number, pairing code, firmware, session length, previous sensor

## Credits

- Knowledge of the sensor's authentication protocol comes from [Juggluco](https://github.com/j-kaltes/Juggluco) and [xDrip](https://github.com/NightscoutFoundation/xDrip).
- The pairing code, pairing UI and sensor application graphics are derived from [DexKit](https://github.com/nightscout/DexKit) by Erik Tolboom.

## License

MIT; see [LICENSE](LICENSE).
