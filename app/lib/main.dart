import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

void main() => runApp(const WormArenaApp());

const lime = Color(0xFFB7F34A);
const dark = Color(0xFF101611);
const panel = Color(0xFF1B261D);

class WormArenaApp extends StatelessWidget {
  const WormArenaApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Worm Arena',
    debugShowCheckedModeBanner: false,
    theme: ThemeData.dark().copyWith(
      scaffoldBackgroundColor: dark,
      colorScheme: ColorScheme.fromSeed(seedColor: lime, brightness: Brightness.dark),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(backgroundColor: lime, foregroundColor: dark,
          padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 18),
          textStyle: const TextStyle(fontWeight: FontWeight.bold)),
      ),
    ),
    home: const HomeScreen(),
  );
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final serverCtrl = TextEditingController(text: 'ws://YOUR_SERVER_HOST:8080');
  final nameCtrl = TextEditingController(text: 'Player');
  final roomCtrl = TextEditingController();
  final id = const Uuid().v4();
  int minutes = 5;
  bool busy = false;
  String? error;

  @override
  void dispose() {
    serverCtrl.dispose(); nameCtrl.dispose(); roomCtrl.dispose(); super.dispose();
  }

  Future<void> enterRoom(bool create) async {
    final server = serverCtrl.text.trim();
    final name = nameCtrl.text.trim().isEmpty ? 'Player' : nameCtrl.text.trim();
    if (!server.startsWith('ws://') && !server.startsWith('wss://')) {
      setState(() => error = 'Enter a WebSocket URL beginning with ws:// or wss://');
      return;
    }
    if (!create && roomCtrl.text.trim().isEmpty) {
      setState(() => error = 'Enter the room code your friend shared.');
      return;
    }
    setState(() { busy = true; error = null; });
    try {
      final channel = WebSocketChannel.connect(Uri.parse(server));
      await channel.ready.timeout(const Duration(seconds: 8));
      final room = create ? '' : roomCtrl.text.trim().toUpperCase();
      channel.sink.add(jsonEncode({
        'type': create ? 'create' : 'join',
        'playerId': id,
        'name': name,
        'roomCode': room,
        'minutes': minutes,
      }));
      if (!mounted) { await channel.sink.close(); return; }
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => LobbyScreen(
        channel: channel, playerId: id, playerName: name,
        initialMinutes: minutes,
      )));
    } catch (e) {
      setState(() => error = 'Could not connect. Check server URL and internet connection.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Widget field(TextEditingController c, String label, {String? hint}) => TextField(
    controller: c, decoration: InputDecoration(labelText: label, hintText: hint,
      filled: true, fillColor: panel, border: OutlineInputBorder(borderRadius: BorderRadius.circular(12))),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    body: SafeArea(child: Center(child: SingleChildScrollView(
      padding: const EdgeInsets.all(22),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480), child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Icon(Icons.sports_esports, size: 68, color: lime),
          const SizedBox(height: 10),
          const Text('WORM ARENA', textAlign: TextAlign.center,
            style: TextStyle(fontSize: 32, fontWeight: FontWeight.w900, letterSpacing: 2)),
          const SizedBox(height: 6),
          const Text('Private rooms. Friends only. Your match.', textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white70)),
          const SizedBox(height: 28),
          field(nameCtrl, 'Player name'),
          const SizedBox(height: 12),
          field(serverCtrl, 'WebSocket server URL', hint: 'wss://your-server.example.com'),
          const SizedBox(height: 20),
          const Text('MATCH DURATION', style: TextStyle(fontWeight: FontWeight.bold, color: lime)),
          const SizedBox(height: 10),
          Row(children: [5, 7, 10].map((m) => Expanded(child: Padding(
            padding: const EdgeInsets.only(right: 8),
            child: ChoiceChip(label: Text('$m min'), selected: minutes == m,
              selectedColor: lime, labelStyle: TextStyle(color: minutes == m ? dark : Colors.white),
              onSelected: (_) => setState(() => minutes = m)),
          ))).toList()),
          const SizedBox(height: 22),
          ElevatedButton(onPressed: busy ? null : () => enterRoom(true),
            child: Text(busy ? 'CONNECTING…' : 'CREATE PRIVATE ROOM')),
          const SizedBox(height: 12),
          field(roomCtrl, 'Room code to join', hint: 'e.g. A7K9Q2'),
          const SizedBox(height: 10),
          OutlinedButton(onPressed: busy ? null : () => enterRoom(false),
            child: const Text('JOIN FRIEND’S ROOM')),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(error!, style: const TextStyle(color: Colors.redAccent)),
          ],
          const SizedBox(height: 20),
          const Text('Prototype • supports 4–8 players per room',
            textAlign: TextAlign.center, style: TextStyle(color: Colors.white54, fontSize: 12)),
        ],
      )),
    ))),
  );
}

class LobbyScreen extends StatefulWidget {
  final WebSocketChannel channel;
  final String playerId, playerName;
  final int initialMinutes;
  const LobbyScreen({super.key, required this.channel, required this.playerId,
    required this.playerName, required this.initialMinutes});
  @override
  State<LobbyScreen> createState() => _LobbyScreenState();
}

class _LobbyScreenState extends State<LobbyScreen> {
  StreamSubscription? sub;
  String roomCode = '…', status = 'Waiting for players';
  int minutes = 5, secondsLeft = 0;
  bool started = false;
  List<Map<String, dynamic>> players = [];
  Map<String, dynamic> positions = {};
  Map<String, dynamic> worms = {};
  List<dynamic> food = [];
  double worldH = 9 / 16;
  double _accDx = 0, _accDy = 0;
  List<Map<String, dynamic>> finalRanking = [];
  Timer? mover;
  final rng = Random();
  DateTime _lastSteerSent = DateTime.fromMillisecondsSinceEpoch(0);

  @override
  void initState() {
    super.initState();
    minutes = widget.initialMinutes;
    sub = widget.channel.stream.listen((raw) {
      try {
        final msg = jsonDecode(raw as String) as Map<String, dynamic>;
        setState(() {
          if (msg['type'] == 'error') status = msg['message'] ?? 'Server error';
          if (msg['type'] == 'state') {
            roomCode = msg['roomCode'] ?? roomCode;
            players = (msg['players'] as List? ?? []).map((e) => Map<String,dynamic>.from(e)).toList();
            positions = Map<String,dynamic>.from(msg['positions'] ?? {});
            worms = Map<String,dynamic>.from(msg['worms'] ?? {});
            food = List<dynamic>.from(msg['food'] ?? []);
            worldH = ((msg['worldH'] ?? worldH) as num).toDouble();
            final wasStarted = started;
            started = msg['started'] == true;
            if (started != wasStarted) {
              _setMatchDisplayMode(started);
            }
            secondsLeft = msg['secondsLeft'] ?? 0;
            minutes = msg['minutes'] ?? minutes;
            status = started ? 'Match in progress' : 'Waiting for players';
          }
          if (msg['type'] == 'ended') { started = false; status = 'Match finished!'; finalRanking = List<Map<String,dynamic>>.from((msg['ranking'] ?? []).map((e) => Map<String,dynamic>.from(e))); }
        });
      } catch (_) {}
    }, onDone: () { if (mounted) setState(() => status = 'Disconnected from server'); });
  }

  Future<void> _setMatchDisplayMode(bool inMatch) async {
    if (inMatch) {
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } else {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.portraitUp,
      ]);
    }
  }

  void send(Map<String, dynamic> data) => widget.channel.sink.add(jsonEncode(data));

  void startMatch() => send({'type': 'start', 'playerId': widget.playerId, 'roomCode': roomCode});
  void move(double dx, double dy) {
    // Pixel-space drag deltas are accumulated between sends so the steering
    // direction is smooth. The arena is letterboxed to a fixed 16:9 world, so a
    // pixel-space direction maps 1:1 to world direction (no stretching).
    _accDx += dx;
    _accDy += dy;
    final now = DateTime.now();
    if (now.difference(_lastSteerSent).inMilliseconds < 35) return;
    final magnitude = sqrt(_accDx * _accDx + _accDy * _accDy);
    if (magnitude < 1.0) return; // ignore sub-pixel jitter, keep accumulating
    _lastSteerSent = now;
    final dxn = _accDx / magnitude, dyn = _accDy / magnitude;
    _accDx = 0; _accDy = 0;
    send({
      'type': 'steer',
      'playerId': widget.playerId,
      'roomCode': roomCode,
      'dx': dxn,
      'dy': dyn,
    });
  }

  @override
  void dispose() {
    sub?.cancel();
    mover?.cancel();
    widget.channel.sink.close();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [DeviceOrientation.portraitUp]);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final me = players.where((p) => p['id'] == widget.playerId).toList();
    final isHost = me.isNotEmpty && me.first['host'] == true;

    if (started) {
      final myPlayer = me.isNotEmpty ? me.first : <String, dynamic>{};
      return Scaffold(
        body: LayoutBuilder(
          builder: (context, constraints) => GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanUpdate: (details) {
              move(details.delta.dx, details.delta.dy);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: ArenaPainter(worms, food, widget.playerId, worldH)),
                Positioned(
                  top: 8,
                  left: 12,
                  right: 12,
                  child: Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          '${secondsLeft ~/ 60}:${(secondsLeft % 60).toString().padLeft(2, '0')}',
                          style: const TextStyle(color: lime, fontSize: 20, fontWeight: FontWeight.bold),
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                        decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(12)),
                        child: Text(
                          'Score ${myPlayer['score'] ?? 0}  •  ${players.length} players',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                const Positioned(
                  left: 12,
                  bottom: 8,
                  child: Text(
                    'DRAG TO STEER',
                    style: TextStyle(color: Colors.white70, fontSize: 11, letterSpacing: 1),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('PRIVATE LOBBY'), backgroundColor: dark),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(color: panel, borderRadius: BorderRadius.circular(16)),
              child: Column(children: [
                const Text('ROOM CODE', style: TextStyle(color: Colors.white60)),
                const SizedBox(height: 4),
                SelectableText(roomCode, style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w900, color: lime, letterSpacing: 4)),
                Text('Share this code with friends • $minutes-minute match'),
                Text(status, style: const TextStyle(color: Colors.white70)),
              ]),
            ),
            const SizedBox(height: 16),
            Text('PLAYERS  ${players.length}/8', style: const TextStyle(fontWeight: FontWeight.bold, color: lime)),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: players.map((p) => ListTile(
                leading: const CircleAvatar(backgroundColor: lime, child: Icon(Icons.person, color: dark)),
                title: Text('${p['name'] ?? 'Player'}${p['id'] == widget.playerId ? ' (You)' : ''}'),
                subtitle: Text('Score: ${p['score'] ?? 0}  •  Length: ${p['length'] ?? 8}${p['alive'] == false ? '  •  Respawning' : ''}'),
                trailing: p['host'] == true ? const Chip(label: Text('HOST')) : null,
              )).toList()),
            ),
            if (finalRanking.isNotEmpty) ...[
              const Text('MATCH RESULTS', textAlign: TextAlign.center, style: TextStyle(color: lime, fontSize: 20, fontWeight: FontWeight.bold)),
              ...finalRanking.take(8).map((p) => ListTile(
                leading: Text('#${p['rank']}', style: const TextStyle(color: lime, fontWeight: FontWeight.bold)),
                title: Text('${p['name']}'),
                trailing: Text('${p['score']} pts'),
              )),
              if (isHost) ElevatedButton(
                onPressed: () { finalRanking.clear(); setState(() {}); startMatch(); },
                child: const Text('PLAY AGAIN'),
              ),
            ] else if (isHost) ...[
              ElevatedButton(onPressed: players.length >= 2 ? startMatch : null, child: const Text('START MATCH')),
              const SizedBox(height: 8),
              const Text(
                'At least 2 players are needed to start. Invite 4–8 friends for the intended experience.',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
    );
  }
}


class ArenaPainter extends CustomPainter {
  final Map<String, dynamic> worms;
  final List<dynamic> food;
  final String myId;
  final double worldH;
  ArenaPainter(this.worms, this.food, this.myId, this.worldH);
  final colors = const [Color(0xFFB7F34A), Color(0xFF58D7FF), Color(0xFFFF8A65),
    Color(0xFFD7A7FF), Color(0xFFFFD54F), Color(0xFFFF80AB), Color(0xFF80CBC4), Colors.white];
  @override
  void paint(Canvas canvas, Size size) {
    // Letterbox the 1.0 x worldH world into the screen with uniform scale.
    final scale = min(size.width / 1.0, size.height / worldH);
    final ox = (size.width - scale) / 2;
    final oy = (size.height - worldH * scale) / 2;
    Offset toScreen(num x, num y) => Offset(ox + x.toDouble() * scale, oy + y.toDouble() * scale);

    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final arena = Rect.fromLTWH(ox, oy, scale, worldH * scale);
    canvas.drawRect(arena, Paint()..color = const Color(0xFF17251A));
    final grid = Paint()..color = Colors.white.withOpacity(.06)..strokeWidth = 1;
    final step = scale / 40;
    for (double x = 0; x <= arena.width; x += step) canvas.drawLine(Offset(ox + x, oy), Offset(ox + x, oy + arena.height), grid);
    for (double y = 0; y <= arena.height; y += step) canvas.drawLine(Offset(ox, oy + y), Offset(ox + arena.width, oy + y), grid);
    canvas.drawRect(arena, Paint()..color = lime.withOpacity(.5)..style = PaintingStyle.stroke..strokeWidth = 2);

    final foodPaint = Paint()..color = const Color(0xFFFFD54F);
    final foodR = max(3.5, scale * 0.012);
    for (final item in food) {
      if (item is! Map) continue;
      canvas.drawCircle(toScreen(item['x'] ?? .5, item['y'] ?? .25), foodR, foodPaint);
    }
    final headR = max(7.0, scale * 0.0115);
    final bodyR = headR * 0.8;
    int i = 0;
    worms.forEach((id, data) {
      if (data is! Map) return;
      if (data['alive'] == false) { i++; return; }
      final trail = (data['trail'] as List? ?? []);
      if (trail.isEmpty) { i++; return; }
      final c = id == myId ? const Color(0xFFB7F34A) : colors[i % colors.length];
      final bodyPaint = Paint()..color = c;
      final outline = Paint()..color = c.withOpacity(.32)..style = PaintingStyle.stroke..strokeWidth = 2;
      for (int j = trail.length - 1; j >= 0; j--) {
        final pt = trail[j];
        if (pt is! Map) continue;
        final o = toScreen(pt['x'] ?? .5, pt['y'] ?? .25);
        canvas.drawCircle(o, j == 0 ? headR : bodyR, bodyPaint);
        if (j == 0) {
          canvas.drawCircle(o, headR * 1.35, outline);
          final eye = Paint()..color = const Color(0xFF101611);
          canvas.drawCircle(o + Offset(-headR * .3, -headR * .25), headR * .18, eye);
          canvas.drawCircle(o + Offset(headR * .3, -headR * .25), headR * .18, eye);
        }
      }
      i++;
    });
  }
  @override
  bool shouldRepaint(covariant ArenaPainter oldDelegate) => true;
}
