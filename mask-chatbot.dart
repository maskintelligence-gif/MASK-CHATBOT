import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:speech_to_text/speech_to_text.dart';
import 'package:image_picker/image_picker.dart';
import 'package:clipboard/clipboard.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    ChangeNotifierProvider(
      create: (_) => ChatProvider(),
      child: const GroqChatApp(),
    ),
  );
}

class GroqChatApp extends StatelessWidget {
  const GroqChatApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Groq AI Chat with Web Search',
      theme: ThemeData.light(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
      ),
      darkTheme: ThemeData.dark(useMaterial3: true).copyWith(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple, brightness: Brightness.dark),
      ),
      themeMode: ThemeMode.system,
      home: const ChatScreen(),
      debugShowCheckedModeBanner: false,
    );
  }
}

class ChatMessage {
  final String text;
  final bool isUser;
  final String? imagePath;
  final bool useWebSearch;

  ChatMessage({
    required this.text,
    required this.isUser,
    this.imagePath,
    this.useWebSearch = false,
  });
}

// SQLite Database Helper
class DatabaseHelper {
  static final DatabaseHelper _instance = DatabaseHelper._internal();
  factory DatabaseHelper() => _instance;
  DatabaseHelper._internal();

  static Database? _database;

  Future<Database> get database async {
    if (_database != null) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<Database> _initDatabase() async {
    Directory documentsDirectory = await getApplicationDocumentsDirectory();
    String path = join(documentsDirectory.path, 'groq_chat.db');
    
    return await openDatabase(
      path,
      version: 2,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE chat_messages(
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        text TEXT NOT NULL,
        is_user BOOLEAN NOT NULL,
        image_path TEXT,
        use_web_search BOOLEAN NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        session_id TEXT DEFAULT 'default'
      )
    ''');
    
    await db.execute('''
      CREATE TABLE chat_sessions(
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL DEFAULT 'New Chat',
        created_at INTEGER NOT NULL,
        last_updated_at INTEGER NOT NULL,
        model_id TEXT
      )
    ''');
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute('ALTER TABLE chat_messages ADD COLUMN use_web_search BOOLEAN NOT NULL DEFAULT 0');
    }
  }

  // Message operations
  Future<int> insertMessage({
    required String text,
    required bool isUser,
    String? imagePath,
    bool useWebSearch = false,
    String sessionId = 'default',
  }) async {
    final db = await database;
    return await db.insert('chat_messages', {
      'text': text,
      'is_user': isUser ? 1 : 0,
      'image_path': imagePath,
      'use_web_search': useWebSearch ? 1 : 0,
      'created_at': DateTime.now().millisecondsSinceEpoch,
      'session_id': sessionId,
    });
  }

  Future<List<Map<String, dynamic>>> getMessages({String sessionId = 'default'}) async {
    final db = await database;
    return await db.query(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
      orderBy: 'created_at ASC',
    );
  }

  Future<void> deleteMessages({String sessionId = 'default'}) async {
    final db = await database;
    await db.delete(
      'chat_messages',
      where: 'session_id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> deleteAllMessages() async {
    final db = await database;
    await db.delete('chat_messages');
  }

  // Session operations
  Future<void> createSession({
    required String sessionId,
    String? name,
    String? modelId,
  }) async {
    final db = await database;
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('chat_sessions', {
      'id': sessionId,
      'name': name ?? 'New Chat',
      'created_at': now,
      'last_updated_at': now,
      'model_id': modelId,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, dynamic>>> getSessions() async {
    final db = await database;
    return await db.query(
      'chat_sessions',
      orderBy: 'last_updated_at DESC',
    );
  }

  Future<void> updateSessionTimestamp(String sessionId) async {
    final db = await database;
    await db.update(
      'chat_sessions',
      {'last_updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [sessionId],
    );
  }

  Future<void> deleteSession(String sessionId) async {
    final db = await database;
    await db.delete(
      'chat_sessions',
      where: 'id = ?',
      whereArgs: [sessionId],
    );
    await deleteMessages(sessionId: sessionId);
  }

  Future<void> close() async {
    if (_database != null) {
      await _database!.close();
      _database = null;
    }
  }
}

class ChatProvider extends ChangeNotifier {
  List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => _messages;
  bool isLoading = false;
  bool _useWebSearch = false;
  
  final DatabaseHelper _dbHelper = DatabaseHelper();
  String _currentSessionId = 'default';

  final List<Map<String, dynamic>> availableModels = [
    {
      'name': 'Llama 3.3 70B (Best)',
      'id': 'llama-3.3-70b-versatile',
      'supportsWebSearch': true,
      'description': 'Best overall model with web search capability'
    },
    {
      'name': 'Llama 3.1 8B (Fast)',
      'id': 'llama-3.1-8b-instant',
      'supportsWebSearch': false,
      'description': 'Fastest response time'
    },
    {
      'name': 'Llama 4 Scout 17B Vision',
      'id': 'meta-llama/llama-4-scout-17b-16e-instruct',
      'supportsWebSearch': false,
      'description': 'Vision + text model'
    },
    {
      'name': 'Llama 4 Maverick 17B Vision',
      'id': 'meta-llama/llama-4-maverick-17b-128e-instruct',
      'supportsWebSearch': false,
      'description': 'Advanced vision model'
    },
    {
      'name': 'GPT-OSS 120B',
      'id': 'openai/gpt-oss-120b',
      'supportsWebSearch': false,
      'description': 'Large open-source model'
    },
    {
      'name': 'GPT-OSS 20B',
      'id': 'openai/gpt-oss-20b',
      'supportsWebSearch': false,
      'description': 'Smaller open-source model'
    },
  ];

  String selectedModel = 'llama-3.3-70b-versatile';

  ChatProvider() {
    _loadHistory();
    _initializeSession();
  }

  Future<void> _initializeSession() async {
    await _dbHelper.createSession(
      sessionId: _currentSessionId,
      modelId: selectedModel,
    );
  }

  void toggleWebSearch() {
    _useWebSearch = !_useWebSearch;
    notifyListeners();
  }

  bool get useWebSearch => _useWebSearch;

  void addMessage(String text, bool isUser, {String? imagePath, bool? useWebSearch}) {
    final message = ChatMessage(
      text: text,
      isUser: isUser,
      imagePath: imagePath,
      useWebSearch: useWebSearch ?? (isUser ? _useWebSearch : false),
    );
    
    _messages.add(message);
    notifyListeners();
    
    // Save to SQLite
    _dbHelper.insertMessage(
      text: text,
      isUser: isUser,
      imagePath: imagePath,
      useWebSearch: message.useWebSearch,
      sessionId: _currentSessionId,
    );
    
    // Update session timestamp
    _dbHelper.updateSessionTimestamp(_currentSessionId);
  }

  void updateLastMessage(String text) {
    if (_messages.isNotEmpty && !_messages.last.isUser) {
      _messages.last = ChatMessage(
        text: text,
        isUser: false,
        useWebSearch: _messages.last.useWebSearch,
      );
      notifyListeners();
    }
  }

  void setLoading(bool loading) {
    isLoading = loading;
    notifyListeners();
  }

  void setModel(String modelId) {
    selectedModel = modelId;
    // Reset web search if model doesn't support it
    final model = availableModels.firstWhere((m) => m['id'] == modelId);
    if (!(model['supportsWebSearch'] ?? false)) {
      _useWebSearch = false;
    }
    notifyListeners();
    
    // Update session with new model
    _dbHelper.createSession(
      sessionId: _currentSessionId,
      modelId: modelId,
    );
  }

  Future<void> _loadHistory() async {
    try {
      final messagesData = await _dbHelper.getMessages(sessionId: _currentSessionId);
      _messages = messagesData.map((e) => ChatMessage(
        text: e['text'] as String,
        isUser: (e['is_user'] as int) == 1,
        imagePath: e['image_path'] as String?,
        useWebSearch: (e['use_web_search'] as int) == 1,
      )).toList();
      notifyListeners();
    } catch (e) {
      print('Error loading history: $e');
      _messages = [];
      notifyListeners();
    }
  }

  void clearHistory() async {
    await _dbHelper.deleteMessages(sessionId: _currentSessionId);
    _messages.clear();
    notifyListeners();
  }

  // Session management methods
  Future<void> createNewSession() async {
    final newSessionId = DateTime.now().millisecondsSinceEpoch.toString();
    _currentSessionId = newSessionId;
    await _dbHelper.createSession(
      sessionId: newSessionId,
      modelId: selectedModel,
    );
    _messages.clear();
    notifyListeners();
  }

  Future<void> loadSession(String sessionId) async {
    _currentSessionId = sessionId;
    await _loadHistory();
  }

  Future<List<Map<String, dynamic>>> getSessions() async {
    return await _dbHelper.getSessions();
  }

  Future<void> deleteSession(String sessionId) async {
    await _dbHelper.deleteSession(sessionId);
    if (sessionId == _currentSessionId) {
      _currentSessionId = 'default';
      await _initializeSession();
      _messages.clear();
      notifyListeners();
    }
  }
  
  bool get currentModelSupportsWebSearch {
    final model = availableModels.firstWhere((m) => m['id'] == selectedModel);
    return (model['supportsWebSearch'] ?? false);
  }
}

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final SpeechToText _speech = SpeechToText();
  bool _isListening = false;

  final String apiKey = const String.fromEnvironment('GROQ_API_KEY', defaultValue: 'YOUR_KEY_HERE');

  Future<void> _sendMessage({String? imagePath, bool? useWebSearch}) async {
    String userText = _controller.text.trim();
    if (userText.isEmpty && imagePath == null) return;

    final provider = Provider.of<ChatProvider>(context, listen: false);
    
    // Determine if web search should be used
    bool shouldUseWebSearch = useWebSearch ?? provider.useWebSearch;
    
    // Check if model supports web search
    if (shouldUseWebSearch && !provider.currentModelSupportsWebSearch) {
      // Show error or fallback to non-web search
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Web search is only available with Llama 3.3 70B model'),
          backgroundColor: Colors.orange,
        ),
      );
      shouldUseWebSearch = false;
    }

    _controller.clear();
    
    provider.addMessage(
      userText,
      true,
      imagePath: imagePath,
      useWebSearch: shouldUseWebSearch,
    );
    
    provider.setLoading(true);
    _scrollToBottom();

    final messages = provider.messages.map((m) {
      List<Map<String, dynamic>> content = [{'type': 'text', 'text': m.text}];
      if (m.imagePath != null) {
        final base64Image = base64Encode(File(m.imagePath!).readAsBytesSync());
        content.insert(0, {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$base64Image'}
        });
      }
      return {
        'role': m.isUser ? 'user' : 'assistant',
        'content': content,
      };
    }).toList();

    // Add web search instruction if enabled
    if (shouldUseWebSearch && provider.currentModelSupportsWebSearch) {
      // Add system message for web search
      messages.insert(0, {
        'role': 'system',
        'content': [
          {
            'type': 'text',
            'text': 'You have access to real-time web search. When the user asks about current events or recent information, use web search to get the latest information. Cite your sources when using web search results.'
          }
        ],
      });
    }

    provider.addMessage('', false, useWebSearch: shouldUseWebSearch);

    final request = http.Request(
      'POST',
      Uri.parse('https://api.groq.com/openai/v1/chat/completions'),
    );

    request.headers.addAll({
      'Authorization': 'Bearer $apiKey',
      'Content-Type': 'application/json',
    });

    // Prepare request body with web search tools if enabled
    Map<String, dynamic> requestBody = {
      'model': provider.selectedModel,
      'messages': messages,
      'temperature': 0.7,
      'stream': true,
    };

    // Add web search tools for models that support it
    if (shouldUseWebSearch && provider.currentModelSupportsWebSearch) {
      requestBody['tools'] = [
        {
          'type': 'web_search_preview',
          'web_search_preview': {
            'search_context_size': 'high',
            'date_range': {
              'start_date': DateTime.now().subtract(Duration(days: 30)).toIso8601String().split('T')[0],
              'end_date': DateTime.now().toIso8601String().split('T')[0],
            }
          }
        }
      ];
      requestBody['tool_choice'] = {'type': 'web_search_preview', 'web_search_preview': {}};
    }

    request.body = jsonEncode(requestBody);

    try {
      final streamedResponse = await request.send();
      String fullResponse = '';

      await for (var chunk in streamedResponse.stream.transform(utf8.decoder)) {
        for (final line in chunk.split('\n')) {
          if (line.startsWith('data: ') && !line.contains('[DONE]')) {
            try {
              final json = jsonDecode(line.substring(6));
              final delta = json['choices']?[0]?['delta']?['content'] as String?;
              if (delta != null) {
                fullResponse += delta;
                provider.updateLastMessage(fullResponse);
                _scrollToBottom();
              }
              
              // Check for web search citations
              final toolCalls = json['choices']?[0]?['delta']?['tool_calls'];
              if (toolCalls != null) {
                // Web search was performed - we could extract and display this
                print('Web search performed: $toolCalls');
              }
            } catch (_) {}
          }
        }
      }
    } catch (e) {
      provider.updateLastMessage('Error: $e');
    } finally {
      provider.setLoading(false);
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _startListening() async {
    bool available = await _speech.initialize();
    if (available) {
      setState(() => _isListening = true);
      _speech.listen(onResult: (result) {
        _controller.text = result.recognizedWords;
      });
    }
  }

  void _stopListening() {
    if (_isListening) {
      _speech.stop();
      setState(() => _isListening = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    final picker = ImagePicker();
    final picked = await picker.pickImage(source: source);
    if (picked != null) {
      _sendMessage(imagePath: picked.path);
    }
  }

  Future<void> _exportChat() async {
    final provider = Provider.of<ChatProvider>(context, listen: false);
    StringBuffer buffer = StringBuffer();
    buffer.writeln('# Groq Chat Export - ${DateTime.now().toIso8601String()}\n');
    
    for (var msg in provider.messages) {
      if (msg.useWebSearch && msg.isUser) {
        buffer.writeln('**${msg.isUser ? 'You' : 'AI'}** 🔍 (Web Search): ${msg.text}');
      } else {
        buffer.writeln('**${msg.isUser ? 'You' : 'AI'}**: ${msg.text}');
      }
      if (msg.imagePath != null) buffer.writeln('(Image attached)');
      buffer.writeln('\n---\n');
    }

    final directory = await getApplicationDocumentsDirectory();
    final file = File('${directory.path}/groq_chat_export.md');
    await file.writeAsString(buffer.toString());

    await Share.shareXFiles([XFile(file.path)], text: 'My Groq AI Chat Export');
  }

  Widget _buildSessionsDrawer(BuildContext context) {
    final provider = Provider.of<ChatProvider>(context, listen: false);
    
    return FutureBuilder<List<Map<String, dynamic>>>(
      future: provider.getSessions(),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return Drawer(
            child: Center(child: CircularProgressIndicator()),
          );
        }
        
        final sessions = snapshot.data ?? [];
        
        return Drawer(
          child: Column(
            children: [
              AppBar(
                title: Text('Chat Sessions'),
                actions: [
                  IconButton(
                    icon: Icon(Icons.add),
                    onPressed: () async {
                      await provider.createNewSession();
                      Navigator.pop(context);
                    },
                  ),
                ],
              ),
              Expanded(
                child: ListView.builder(
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final session = sessions[index];
                    return ListTile(
                      title: Text(session['name'] ?? 'Chat ${session['id']}'),
                      subtitle: Text(
                        DateTime.fromMillisecondsSinceEpoch(session['last_updated_at'])
                            .toString()
                            .split('.')[0],
                      ),
                      trailing: IconButton(
                        icon: Icon(Icons.delete, size: 20),
                        onPressed: () async {
                          await provider.deleteSession(session['id']);
                          setState(() {});
                        },
                      ),
                      onTap: () async {
                        await provider.loadSession(session['id']);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildWebSearchButton(BuildContext context) {
    final provider = Provider.of<ChatProvider>(context);
    
    if (!provider.currentModelSupportsWebSearch) {
      return Tooltip(
        message: 'Web search only available with Llama 3.3 70B',
        child: Opacity(
          opacity: 0.5,
          child: IconButton(
            icon: Icon(Icons.search, color: Colors.grey),
            onPressed: null,
          ),
        ),
      );
    }

    return IconButton(
      icon: Icon(
        provider.useWebSearch ? Icons.search : Icons.search_off,
        color: provider.useWebSearch ? Colors.blue : null,
      ),
      tooltip: provider.useWebSearch ? 'Web Search ON - Click to turn off' : 'Web Search OFF - Click to turn on',
      onPressed: () {
        provider.toggleWebSearch();
        if (provider.useWebSearch) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Web search enabled - Next message will use web search'),
              backgroundColor: Colors.blue,
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
    );
  }

  void _sendWithWebSearch() {
    _sendMessage(useWebSearch: true);
  }

  @override
  Widget build(BuildContext context) {
    final provider = Provider.of<ChatProvider>(context);
    final currentModel = provider.availableModels.firstWhere((m) => m['id'] == provider.selectedModel);
    final currentModelName = currentModel['name'] as String;
    final supportsWebSearch = currentModel['supportsWebSearch'] as bool? ?? false;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Groq AI Chat'),
        actions: [
          // Web search toggle
          _buildWebSearchButton(context),
          // Sessions button
          IconButton(
            icon: Icon(Icons.history),
            onPressed: () => Scaffold.of(context).openDrawer(),
          ),
          IconButton(icon: const Icon(Icons.share), onPressed: _exportChat),
          PopupMenuButton<String>(
            onSelected: (value) {
              if (value == 'clear') {
                provider.clearHistory();
              } else if (value == 'new_session') {
                provider.createNewSession();
              }
            },
            itemBuilder: (_) => [
              const PopupMenuItem(value: 'new_session', child: Text('New Chat Session')),
              const PopupMenuItem(value: 'clear', child: Text('Clear History')),
            ],
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(48),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                const Icon(Icons.smart_toy, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    currentModelName,
                    style: const TextStyle(fontSize: 14),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (supportsWebSearch)
                  Container(
                    margin: EdgeInsets.only(left: 8),
                    padding: EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Text(
                      'Web Search',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.blue,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      drawer: _buildSessionsDrawer(context),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DropdownButtonFormField<String>(
                  value: provider.selectedModel,
                  decoration: InputDecoration(
                    labelText: 'Select Model',
                    border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  items: provider.availableModels.map((m) {
                    return DropdownMenuItem(
                      value: m['id'],
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(m['name']!),
                          if (m['description'] != null)
                            Text(
                              m['description']!,
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.6),
                              ),
                            ),
                          if (m['supportsWebSearch'] == true)
                            Container(
                              margin: EdgeInsets.only(top: 2),
                              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: Colors.blue.withOpacity(0.1),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Web Search',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.blue,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
                        ],
                      ),
                    );
                  }).toList(),
                  onChanged: (val) => provider.setModel(val!),
                ),
                if (provider.useWebSearch && provider.currentModelSupportsWebSearch)
                  Container(
                    margin: EdgeInsets.only(top: 8),
                    padding: EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.blue.withOpacity(0.1),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.blue.withOpacity(0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.search, color: Colors.blue, size: 20),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Web search is ENABLED. Your next message will search the web for current information.',
                            style: TextStyle(
                              color: Colors.blue,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(Icons.close, size: 16),
                          onPressed: () => provider.toggleWebSearch(),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: provider.messages.length,
              itemBuilder: (context, index) {
                final msg = provider.messages[index];
                final bool hasCode = RegExp(r'```').hasMatch(msg.text);

                return Align(
                  alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
                  child: Container(
                    constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.85),
                    margin: const EdgeInsets.symmetric(vertical: 8),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: msg.isUser
                          ? Theme.of(context).colorScheme.primary
                          : Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withOpacity(0.05),
                          blurRadius: 8,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (msg.imagePath != null)
                          ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(File(msg.imagePath!), height: 220, fit: BoxFit.cover),
                          ),
                        if (msg.useWebSearch && msg.isUser)
                          Container(
                            margin: EdgeInsets.only(bottom: 8),
                            padding: EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.blue.withOpacity(0.1),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.search, size: 12, color: Colors.blue),
                                SizedBox(width: 4),
                                Text(
                                  'Web Search',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.blue,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        if (msg.text.isNotEmpty)
                          SelectionArea(
                            child: MarkdownBody(
                              data: msg.text,
                              styleSheet: MarkdownStyleSheet(
                                p: TextStyle(
                                  color: msg.isUser ? Colors.white : Theme.of(context).colorScheme.onSurface,
                                  fontSize: 16,
                                ),
                                code: TextStyle(
                                  backgroundColor: Colors.black.withOpacity(0.1),
                                  fontFamily: 'monospace',
                                  fontSize: 14,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.05),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              builders: {
                                'code': CodeElementBuilder(hasCopy: hasCode),
                              },
                            ),
                          ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          if (provider.isLoading)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 3, color: Theme.of(context).colorScheme.primary),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    provider.useWebSearch ? 'Searching the web...' : 'Thinking at lightning speed...',
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surface,
              boxShadow: [BoxShadow(color: Colors.black.withOpacity(0.1), blurRadius: 10)],
            ),
            child: Row(
              children: [
                IconButton(icon: const Icon(Icons.photo_camera), onPressed: () => _pickImage(ImageSource.camera)),
                IconButton(icon: const Icon(Icons.image), onPressed: () => _pickImage(ImageSource.gallery)),
                Expanded(
                  child: TextField(
                    controller: _controller,
                    decoration: InputDecoration(
                      hintText: provider.useWebSearch ? 'Ask about current events...' : 'Ask anything...',
                      border: OutlineInputBorder(borderRadius: BorderRadius.circular(32)),
                      filled: true,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                    ),
                    maxLines: null,
                    onSubmitted: (_) => _sendMessage(),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: Icon(_isListening ? Icons.mic : Icons.mic_off, color: _isListening ? Colors.red : null),
                  onPressed: _isListening ? _stopListening : _startListening,
                ),
                const SizedBox(width: 8),
                if (provider.currentModelSupportsWebSearch && !provider.useWebSearch)
                  Tooltip(
                    message: 'Send with web search',
                    child: IconButton(
                      icon: Icon(Icons.search, color: Colors.blue),
                      onPressed: () => _sendWithWebSearch(),
                    ),
                  ),
                FloatingActionButton(
                  onPressed: _sendMessage,
                  mini: true,
                  child: const Icon(Icons.send),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  final bool hasCopy;

  CodeElementBuilder({required this.hasCopy});

  @override
  Widget visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final code = element.textContent;
    return Stack(
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: Colors.grey[900],
            borderRadius: BorderRadius.circular(8),
          ),
          child: SelectableText(
            code,
            style: const TextStyle(color: Colors.white, fontFamily: 'monospace', fontSize: 14),
          ),
        ),
        if (hasCopy)
          Positioned(
            top: 4,
            right: 4,
            child: IconButton(
              icon: const Icon(Icons.copy, color: Colors.white70, size: 18),
              onPressed: () {
                FlutterClipboard.copy(code).then((_) {
                  ScaffoldMessenger.of(FlutterClipboard.context!).showSnackBar(const SnackBar(content: Text('Code copied!')));
                });
              },
            ),
          ),
      ],
    );
  }
}