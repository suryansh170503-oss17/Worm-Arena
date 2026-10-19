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
// Colors are assigned by the SERVER (players[].color) so every phone shows the same colors.
const wormColors = [Color(0xFFB7F34A), Color(0xFF58D7FF), Color(0xFFFF8A65),
  Color(0xFFD7A7FF), Color(0xFFFFD54F), Color(0xFFFF80AB), Color(0xFF80CBC4), Colors.white];
Color colorOf(dynamic i) => wormColors[((i ?? 0) as num).toInt() % wormColors.length];

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
  double worldW = 3.0, worldH = 3.0 * 9 / 16;
  String endReason = '';
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
            if (msg.containsKey('food')) food = List<dynamic>.from(msg['food'] ?? []); // sent only when it changes
            worldW = ((msg['worldW'] ?? worldW) as num).toDouble();
            worldH = ((msg['worldH'] ?? worldH) as num).toDouble();
            final wasStarted = started;
            started = msg['started'] == true;
            if (started != wasStarted) {
              _setMatchDisplayMode(started);
              if (started) { finalRanking = []; endReason = ''; }
            }
            secondsLeft = msg['secondsLeft'] ?? 0;
            minutes = msg['minutes'] ?? minutes;
            status = started ? 'Match in progress' : 'Waiting for players';
          }
          if (msg['type'] == 'ended') {
            if (started) _setMatchDisplayMode(false); // return to portrait lobby + show system bars
            started = false;
            status = 'Match finished!';
            endReason = '${msg['reason'] ?? ''}';
            finalRanking = List<Map<String,dynamic>>.from((msg['ranking'] ?? []).map((e) => Map<String,dynamic>.from(e)));
          }
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
    // Less sensitive steering: pixel deltas are accumulated, tiny jitter is ignored,
    // and the server additionally limits how fast the worm can turn (TURN_RATE).
    _accDx += dx;
    _accDy += dy;
    final now = DateTime.now();
    if (now.difference(_lastSteerSent).inMilliseconds < 50) return;
    final magnitude = sqrt(_accDx * _accDx + _accDy * _accDy);
    if (magnitude < 5.0) return; // dead zone in pixels; keep accumulating
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
            onPanStart: (_) { _accDx = 0; _accDy = 0; },
            onPanUpdate: (details) {
              move(details.delta.dx, details.delta.dy);
            },
            child: Stack(
              fit: StackFit.expand,
              children: [
                CustomPaint(painter: ArenaPainter(worms, food, widget.playerId, worldW, worldH)),
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
                          'Score ${myPlayer['score'] ?? 0}  •  Alive ${players.where((p) => p['alive'] == true).length}/${players.length}',
                          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                ),
                if (myPlayer['alive'] == false)
                  Positioned(
                    top: 52, left: 0, right: 0,
                    child: Center(child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                      decoration: BoxDecoration(color: Colors.redAccent.withOpacity(.85), borderRadius: BorderRadius.circular(12)),
                      child: const Text('ELIMINATED — watching the rest', style: TextStyle(fontWeight: FontWeight.bold)),
                    )),
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
                leading: CircleAvatar(backgroundColor: colorOf(p['color']), child: const Icon(Icons.person, color: dark)),
                title: Text('${p['name'] ?? 'Player'}${p['id'] == widget.playerId ? ' (You)' : ''}'),
                subtitle: Text('Score: ${p['score'] ?? 0}  •  Length: ${p['length'] ?? 8}'),
                trailing: p['host'] == true ? const Chip(label: Text('HOST')) : null,
              )).toList()),
            ),
            if (finalRanking.isNotEmpty) ...[
              Text('WINNER: ${finalRanking.first['name']}', textAlign: TextAlign.center,
                style: const TextStyle(color: lime, fontSize: 24, fontWeight: FontWeight.w900)),
              Text(endReason == 'last_alive' ? 'Last worm standing' : endReason == 'time' ? 'Time up — highest score' : 'Everyone was eliminated — highest score',
                textAlign: TextAlign.center, style: const TextStyle(color: Colors.white60)),
              const SizedBox(height: 6),
              ...finalRanking.take(8).map((p) => ListTile(
                leading: Text('#${p['rank']}', style: TextStyle(color: colorOf(p['color']), fontWeight: FontWeight.bold)),
                title: Text('${p['name']}'),
                trailing: Text('${p['score']} pts • len ${p['length']}'),
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
  final List<dynamic> food; // flat [x0,y0,x1,y1,...]
  final String myId;
  final double worldW, worldH;
  ArenaPainter(this.worms, this.food, this.myId, this.worldW, this.worldH);

  static const double viewW = 1.0; // world units visible across the screen width

  // Flat [x,y,x,y...] -> point i
  Offset _pt(List l, int i) => Offset((l[2 * i] as num).toDouble(), (l[2 * i + 1] as num).toDouble());

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / viewW;
    final viewH = size.height / scale;

    // Camera: follow my worm; if I'm eliminated, watch the first surviving worm.
    Offset? focus;
    final mine = worms[myId];
    if (mine is Map && (mine['trail'] as List? ?? []).length >= 2) {
      focus = _pt(mine['trail'] as List, 0);
    } else {
      for (final w in worms.values) {
        if (w is Map && (w['trail'] as List? ?? []).length >= 2) { focus = _pt(w['trail'] as List, 0); break; }
      }
    }
    focus ??= Offset(worldW / 2, worldH / 2);
    final cx = focus.dx.clamp(min(viewW / 2, worldW / 2), max(worldW - viewW / 2, worldW / 2)).toDouble();
    final cy = focus.dy.clamp(min(viewH / 2, worldH / 2), max(worldH - viewH / 2, worldH / 2)).toDouble();
    final left = cx - viewW / 2, top = cy - viewH / 2;
    Offset toScreen(double x, double y) => Offset((x - left) * scale, (y - top) * scale);

    canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
    final arena = Rect.fromPoints(toScreen(0, 0), toScreen(worldW, worldH));
    canvas.drawRect(arena, Paint()..color = const Color(0xFF17251A));

    // Grid (world-anchored so movement is visible)
    final grid = Paint()..color = Colors.white.withOpacity(.06)..strokeWidth = 1;
    const step = 0.05;
    for (double gx = (left / step).floorToDouble() * step; gx <= left + viewW; gx += step) {
      if (gx < 0 || gx > worldW) continue;
      final sx = (gx - left) * scale;
      canvas.drawLine(Offset(sx, max(0, arena.top)), Offset(sx, min(size.height, arena.bottom)), grid);
    }
    for (double gy = (top / step).floorToDouble() * step; gy <= top + viewH; gy += step) {
      if (gy < 0 || gy > worldH) continue;
      final sy = (gy - top) * scale;
      canvas.drawLine(Offset(max(0, arena.left), sy), Offset(min(size.width, arena.right), sy), grid);
    }
    canvas.drawRect(arena, Paint()..color = Colors.redAccent.withOpacity(.7)..style = PaintingStyle.stroke..strokeWidth = 3);

    // Food
    final foodPaint = Paint()..color = const Color(0xFFFFD54F);
    final foodR = max(3.5, scale * 0.012);
    for (int i = 0; i + 1 < food.length; i += 2) {
      final o = toScreen((food[i] as num).toDouble(), (food[i + 1] as num).toDouble());
      if (o.dx < -10 || o.dy < -10 || o.dx > size.width + 10 || o.dy > size.height + 10) continue;
      canvas.drawCircle(o, foodR, foodPaint);
    }

    // Worms (color comes from the server so all phones agree)
    final headR = max(7.0, scale * 0.0115);
    final bodyR = headR * 0.8;
    for (final entry in worms.entries) {
      final data = entry.value;
      if (data is! Map || data['alive'] == false) continue;
      final trail = (data['trail'] as List? ?? []);
      final n = trail.length ~/ 2;
      if (n == 0) continue;
      final c = colorOf(data['color']);
      final bodyPaint = Paint()..color = c;
      final isMe = entry.key == myId;
      for (int j = n - 1; j >= 0; j--) {
        final o = toScreen(_pt(trail, j).dx, _pt(trail, j).dy);
        canvas.drawCircle(o, j == 0 ? headR : bodyR, bodyPaint);
        if (j == 0) {
          canvas.drawCircle(o, headR * 1.35, Paint()..color = (isMe ? Colors.white : c).withOpacity(isMe ? .8 : .32)..style = PaintingStyle.stroke..strokeWidth = 2);
          final eye = Paint()..color = const Color(0xFF101611);
          canvas.drawCircle(o + Offset(-headR * .3, -headR * .25), headR * .18, eye);
          canvas.drawCircle(o + Offset(headR * .3, -headR * .25), headR * .18, eye);
        }
      }
    }

    // Minimap (bottom-right)
    const mw = 120.0;
    final mh = mw * worldH / worldW;
    final mr = Rect.fromLTWH(size.width - mw - 12, size.height - mh - 12, mw, mh);
    canvas.drawRect(mr, Paint()..color = Colors.black.withOpacity(.55));
    canvas.drawRect(mr, Paint()..color = Colors.white30..style = PaintingStyle.stroke);
    Offset mm(Offset w) => Offset(mr.left + w.dx / worldW * mw, mr.top + w.dy / worldH * mh);
    canvas.drawRect(Rect.fromPoints(mm(Offset(left, top)), mm(Offset(left + viewW, top + viewH))),
      Paint()..color = Colors.white54..style = PaintingStyle.stroke);
    for (final entry in worms.entries) {
      final data = entry.value;
      if (data is! Map || data['alive'] == false) continue;
      final trail = (data['trail'] as List? ?? []);
      if (trail.length < 2) continue;
      canvas.drawCircle(mm(_pt(trail, 0)), entry.key == myId ? 3.5 : 2.5, Paint()..color = colorOf(data['color']));
    }
  }
  @override
  bool shouldRepaint(covariant ArenaPainter oldDelegate) => true;
}
