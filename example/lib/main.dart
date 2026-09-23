import 'dart:typed_data';

import 'package:audio_valuation/audio_valuation.dart';
import 'package:flutter/material.dart';

void main() => runApp(const DemoApp());

class DemoApp extends StatelessWidget {
  const DemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Transcription',
        theme: ThemeData(
          colorSchemeSeed: const Color(0xFF1F4E79),
          useMaterial3: true,
        ),
        home: const TranscriptionScreen(),
      );
}

class TranscriptionScreen extends StatefulWidget {
  const TranscriptionScreen({super.key});

  @override
  State<TranscriptionScreen> createState() => _TranscriptionScreenState();
}

class _TranscriptionScreenState extends State<TranscriptionScreen> {
  final _recorder = TranscriptionRecorder();

  Transcriber? _transcriber;
  String _status = 'Loading speech model…';
  bool _recording = false;
  bool _busy = false;
  TranscriptionResult? _result;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadModel();
  }

  Future<void> _loadModel() async {
    try {
      final transcriber = await WhisperTranscriber.load(whisperModelPath);
      if (!mounted) {
        await transcriber.dispose();
        return;
      }
      setState(() {
        _transcriber = transcriber;
        _status = 'Ready — running fully on device';
      });
    } on ModelNotDownloadedException catch (error) {
      // A real app would offer the download here (to error.path), then call
      // _loadModel again once it completes.
      setState(() => _status = error.message);
    } on TranscriptionException catch (error) {
      setState(() => _status = error.message);
    }
  }

  Future<void> _toggleRecording() async {
    if (_recording) {
      final pcm = await _recorder.stop();
      setState(() => _recording = false);
      await _transcribe(pcm);
      return;
    }

    if (!await _recorder.hasPermission()) {
      setState(() => _error = 'Microphone permission denied');
      return;
    }
    await _recorder.start();
    setState(() {
      _recording = true;
      _result = null;
      _error = null;
    });
  }

  Future<void> _transcribe(Uint8List pcm) async {
    final transcriber = _transcriber;
    if (transcriber == null) return;

    setState(() => _busy = true);
    try {
      // Raw PCM16 goes straight to the worker isolate; nothing is converted
      // here on the UI isolate.
      final result = await transcriber.transcribePcm16(
        pcm,
        languageCode: 'en-IN',
      );
      setState(() {
        _result = result;
        _error = null;
      });
    } on TranscriptionException catch (error) {
      setState(() {
        _error = error.message;
        _result = null;
      });
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _recorder.dispose();
    _transcriber?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Speech to text')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(_status, style: theme.textTheme.bodySmall),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _transcriber == null || _busy ? null : _toggleRecording,
              icon: Icon(_recording ? Icons.stop : Icons.mic),
              label: Text(_recording ? 'Stop and transcribe' : 'Record'),
            ),
            const SizedBox(height: 24),
            if (_busy) const Center(child: CircularProgressIndicator()),
            if (_error != null)
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            if (result != null) ...[
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(
                    result.isEmpty ? '(no speech detected)' : result.text,
                    style: theme.textTheme.titleMedium,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '${result.audioSeconds.toStringAsFixed(1)} s of audio in '
                '${result.processingTime.inMilliseconds} ms '
                '(${result.realTimeFactor.toStringAsFixed(1)}× real time)',
                style: theme.textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}
