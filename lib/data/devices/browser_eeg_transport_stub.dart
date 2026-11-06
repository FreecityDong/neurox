import 'eeg_transport.dart';

EegTransport createBrowserEegTransport() =>
    throw UnsupportedError('Web Bluetooth requires a browser');
