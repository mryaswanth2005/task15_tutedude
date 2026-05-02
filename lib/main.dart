import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const TodoReminderApp());
}

class TodoReminderApp extends StatelessWidget {
  const TodoReminderApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF185D6B),
      brightness: Brightness.light,
    );

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Task15 Reminders',
      theme: ThemeData(
        colorScheme: colorScheme,
        scaffoldBackgroundColor: const Color(0xFFF4F7F9),
        useMaterial3: true,
      ),
      home: const TodoHomePage(),
    );
  }
}

class TodoHomePage extends StatefulWidget {
  const TodoHomePage({super.key});

  @override
  State<TodoHomePage> createState() => _TodoHomePageState();
}

class _TodoHomePageState extends State<TodoHomePage> {
  final TodoRepository _repository = TodoRepository();
  final ReminderNotificationService _notifications =
      ReminderNotificationService.instance;

  List<TodoItem> _todos = <TodoItem>[];
  bool _isLoading = true;
  bool _isSaving = false;
  String? _errorMessage;

  @override
  void initState() {
    super.initState();
    _loadTodos();
  }

  Future<void> _loadTodos() async {
    try {
      final todos = await _repository.loadTodos();
      if (!mounted) {
        return;
      }

      setState(() {
        _todos = todos;
        _isLoading = false;
        _errorMessage = null;
      });
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _isLoading = false;
        _errorMessage = 'Unable to load your tasks right now.';
      });
    }
  }

  Future<void> _showMessage(String message) async {
    if (!mounted) {
      return;
    }

    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  List<TodoItem> get _sortedTodos {
    final todos = List<TodoItem>.from(_todos);
    todos.sort((left, right) {
      if (left.isDone != right.isDone) {
        return left.isDone ? 1 : -1;
      }

      final leftReminder = left.reminderAt;
      final rightReminder = right.reminderAt;

      if (leftReminder == null && rightReminder == null) {
        return right.id.compareTo(left.id);
      }
      if (leftReminder == null) {
        return 1;
      }
      if (rightReminder == null) {
        return -1;
      }

      return leftReminder.compareTo(rightReminder);
    });
    return todos;
  }

  Future<void> _addTodo() async {
    await _editTodo();
  }

  Future<void> _editTodo({TodoItem? todo}) async {
    final draft = await _showTodoDialog(existing: todo);
    if (draft == null) {
      return;
    }

    setState(() {
      _isSaving = true;
    });

    final previousTodos = List<TodoItem>.from(_todos);
    final nextTodos = List<TodoItem>.from(_todos);
    final now = DateTime.now();

    try {
      final updatedTodo = todo == null
          ? TodoItem(
              id: await _repository.nextId(),
              title: draft.title,
              reminderAt: draft.reminderAt,
            )
          : todo.copyWith(title: draft.title, reminderAt: draft.reminderAt);

      if (todo == null) {
        nextTodos.add(updatedTodo);
      } else {
        final index = nextTodos.indexWhere((item) => item.id == todo.id);
        if (index != -1) {
          nextTodos[index] = updatedTodo;
        }
      }

      await _repository.saveTodos(nextTodos);

      if (todo != null && todo.reminderAt != draft.reminderAt) {
        await _notifications.cancelReminder(todo.id);
      }

      if (draft.reminderAt != null && draft.reminderAt!.isAfter(now)) {
        final notificationsGranted = await _notifications.requestPermissions();
        if (notificationsGranted) {
          await _notifications.scheduleReminder(updatedTodo);
        } else {
          await _showMessage(
            'Task saved, but notification permission was not granted.',
          );
        }
      } else {
        await _notifications.cancelReminder(updatedTodo.id);
      }

      if (!mounted) {
        return;
      }

      setState(() {
        _todos = nextTodos;
      });
      await _showMessage(todo == null ? 'Task added.' : 'Task updated.');
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _todos = previousTodos;
      });
      await _showMessage('Could not save the task. Please try again.');
    } finally {
      if (mounted) {
        setState(() {
          _isSaving = false;
        });
      }
    }
  }

  Future<void> _toggleDone(TodoItem todo, bool value) async {
    final previousTodos = List<TodoItem>.from(_todos);
    final updatedTodos = _todos
        .map((item) => item.id == todo.id ? item.copyWith(isDone: value) : item)
        .toList();

    setState(() {
      _todos = updatedTodos;
    });

    try {
      await _repository.saveTodos(updatedTodos);

      if (value) {
        await _notifications.cancelReminder(todo.id);
      } else if (todo.reminderAt != null &&
          todo.reminderAt!.isAfter(DateTime.now())) {
        final notificationsGranted = await _notifications.requestPermissions();
        if (notificationsGranted) {
          await _notifications.scheduleReminder(todo.copyWith(isDone: false));
        }
      }
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _todos = previousTodos;
      });
      await _showMessage('Could not update the task status.');
    }
  }

  Future<void> _deleteTodo(TodoItem todo) async {
    final previousTodos = List<TodoItem>.from(_todos);
    final updatedTodos = _todos.where((item) => item.id != todo.id).toList();

    setState(() {
      _todos = updatedTodos;
    });

    try {
      await _repository.saveTodos(updatedTodos);
      await _notifications.cancelReminder(todo.id);
      await _showMessage('Task deleted.');
    } catch (_) {
      if (!mounted) {
        return;
      }

      setState(() {
        _todos = previousTodos;
      });
      await _showMessage('Could not delete the task.');
    }
  }

  Future<void> _requestNotificationAccess() async {
    final granted = await _notifications.requestPermissions();
    if (!mounted) {
      return;
    }

    if (granted) {
      await _notifications.schedulePendingReminders(_todos);
    }

    await _showMessage(
      granted
          ? 'Notification permission is ready.'
          : 'Notification permission was not granted.',
    );
  }

  Future<_TodoDraft?> _showTodoDialog({TodoItem? existing}) async {
    final titleController = TextEditingController(text: existing?.title ?? '');
    final initialReminder =
        existing?.reminderAt ?? DateTime.now().add(const Duration(hours: 1));
    bool reminderEnabled = existing?.reminderAt != null;
    DateTime selectedDate = DateTime(
      initialReminder.year,
      initialReminder.month,
      initialReminder.day,
    );
    TimeOfDay selectedTime = TimeOfDay.fromDateTime(initialReminder);
    String? errorText;

    final result = await showDialog<_TodoDraft>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            Future<void> pickDate() async {
              final pickedDate = await showDatePicker(
                context: context,
                initialDate: selectedDate,
                firstDate: DateTime.now().subtract(const Duration(days: 1)),
                lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
              );

              if (pickedDate == null) {
                return;
              }

              setDialogState(() {
                selectedDate = DateTime(
                  pickedDate.year,
                  pickedDate.month,
                  pickedDate.day,
                );
                errorText = null;
              });
            }

            Future<void> pickTime() async {
              final pickedTime = await showTimePicker(
                context: context,
                initialTime: selectedTime,
              );

              if (pickedTime == null) {
                return;
              }

              setDialogState(() {
                selectedTime = pickedTime;
                errorText = null;
              });
            }

            final reminderDateTime = DateTime(
              selectedDate.year,
              selectedDate.month,
              selectedDate.day,
              selectedTime.hour,
              selectedTime.minute,
            );

            return AlertDialog(
              title: Text(existing == null ? 'Add task' : 'Edit task'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      controller: titleController,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Task title',
                        border: OutlineInputBorder(),
                      ),
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: 16),
                    SwitchListTile.adaptive(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Enable reminder'),
                      subtitle: const Text(
                        'Schedule a push notification for this task.',
                      ),
                      value: reminderEnabled,
                      onChanged: (value) {
                        setDialogState(() {
                          reminderEnabled = value;
                          errorText = null;
                        });
                      },
                    ),
                    if (reminderEnabled) ...[
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: pickDate,
                        icon: const Icon(Icons.calendar_month_outlined),
                        label: Text(
                          DateFormat.yMMMMd().format(reminderDateTime),
                        ),
                      ),
                      const SizedBox(height: 8),
                      OutlinedButton.icon(
                        onPressed: pickTime,
                        icon: const Icon(Icons.schedule_outlined),
                        label: Text(
                          MaterialLocalizations.of(
                            context,
                          ).formatTimeOfDay(selectedTime),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Reminder time: ${DateFormat.yMMMd().add_jm().format(reminderDateTime)}',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                    if (errorText != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        errorText!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () {
                    final title = titleController.text.trim();
                    if (title.isEmpty) {
                      setDialogState(() {
                        errorText = 'Please enter a task title.';
                      });
                      return;
                    }

                    DateTime? reminderAt;
                    if (reminderEnabled) {
                      final candidate = DateTime(
                        selectedDate.year,
                        selectedDate.month,
                        selectedDate.day,
                        selectedTime.hour,
                        selectedTime.minute,
                      );

                      if (!candidate.isAfter(DateTime.now())) {
                        setDialogState(() {
                          errorText = 'Pick a reminder time in the future.';
                        });
                        return;
                      }

                      reminderAt = candidate;
                    }

                    Navigator.of(
                      dialogContext,
                    ).pop(_TodoDraft(title: title, reminderAt: reminderAt));
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );

    titleController.dispose();
    return result;
  }

  @override
  Widget build(BuildContext context) {
    final todos = _sortedTodos;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Task15 Reminders'),
        actions: [
          IconButton(
            tooltip: 'Enable notifications',
            onPressed: _isSaving ? null : _requestNotificationAccess,
            icon: const Icon(Icons.notifications_active_outlined),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _isSaving ? null : _addTodo,
        icon: const Icon(Icons.add),
        label: const Text('Add task'),
      ),
      body: AnimatedSwitcher(
        duration: const Duration(milliseconds: 250),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : _errorMessage != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text(
                    _errorMessage!,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
              )
            : todos.isEmpty
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.task_alt_outlined,
                        size: 72,
                        color: Theme.of(context).colorScheme.primary,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'No tasks yet',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Add a task and choose a reminder time to get a notification later.',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
              )
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
                itemCount: todos.length,
                separatorBuilder: (_, __) => const SizedBox(height: 12),
                itemBuilder: (context, index) {
                  final todo = todos[index];
                  return _TodoCard(
                    todo: todo,
                    onToggleDone: (value) => _toggleDone(todo, value),
                    onEdit: () => _editTodo(todo: todo),
                    onDelete: () => _deleteTodo(todo),
                  );
                },
              ),
      ),
    );
  }
}

class _TodoCard extends StatelessWidget {
  const _TodoCard({
    required this.todo,
    required this.onToggleDone,
    required this.onEdit,
    required this.onDelete,
  });

  final TodoItem todo;
  final ValueChanged<bool> onToggleDone;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final reminderText = todo.reminderAt == null
        ? 'No reminder set'
        : DateFormat.yMMMd().add_jm().format(todo.reminderAt!);

    return Card(
      elevation: 0,
      color: theme.colorScheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Checkbox(
                value: todo.isDone,
                onChanged: (value) {
                  if (value != null) {
                    onToggleDone(value);
                  }
                },
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    todo.title,
                    style: theme.textTheme.titleMedium?.copyWith(
                      decoration: todo.isDone
                          ? TextDecoration.lineThrough
                          : null,
                      color: todo.isDone
                          ? theme.colorScheme.onSurfaceVariant
                          : theme.colorScheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _StatusChip(label: todo.isDone ? 'Completed' : 'Pending'),
                      _StatusChip(label: reminderText),
                    ],
                  ),
                ],
              ),
            ),
            Column(
              children: [
                IconButton(
                  tooltip: 'Edit task',
                  onPressed: onEdit,
                  icon: const Icon(Icons.edit_outlined),
                ),
                IconButton(
                  tooltip: 'Delete task',
                  onPressed: onDelete,
                  icon: const Icon(Icons.delete_outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Chip(
      label: Text(label),
      visualDensity: VisualDensity.compact,
      side: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
    );
  }
}

class TodoItem {
  TodoItem({
    required this.id,
    required this.title,
    required this.reminderAt,
    this.isDone = false,
  });

  final int id;
  final String title;
  final DateTime? reminderAt;
  final bool isDone;

  TodoItem copyWith({String? title, DateTime? reminderAt, bool? isDone}) {
    return TodoItem(
      id: id,
      title: title ?? this.title,
      reminderAt: reminderAt,
      isDone: isDone ?? this.isDone,
    );
  }

  factory TodoItem.fromMap(Map<String, dynamic> json) {
    return TodoItem(
      id: json['id'] as int? ?? 0,
      title: json['title'] as String? ?? '',
      reminderAt: json['reminderAt'] == null
          ? null
          : DateTime.tryParse(json['reminderAt'] as String),
      isDone: json['isDone'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toMap() {
    return <String, dynamic>{
      'id': id,
      'title': title,
      'reminderAt': reminderAt?.toIso8601String(),
      'isDone': isDone,
    };
  }
}

class TodoRepository {
  static const String _todosKey = 'todo_items';
  static const String _nextIdKey = 'todo_next_id';

  Future<List<TodoItem>> loadTodos() async {
    final preferences = await SharedPreferences.getInstance();
    final rawTodos = preferences.getStringList(_todosKey) ?? <String>[];

    final todos = <TodoItem>[];
    for (final entry in rawTodos) {
      try {
        final decoded = jsonDecode(entry);
        if (decoded is Map<String, dynamic>) {
          final item = TodoItem.fromMap(decoded);
          if (item.title.isNotEmpty) {
            todos.add(item);
          }
        }
      } catch (_) {
        continue;
      }
    }

    return todos;
  }

  Future<void> saveTodos(List<TodoItem> todos) async {
    final preferences = await SharedPreferences.getInstance();
    final encoded = todos.map((todo) => jsonEncode(todo.toMap())).toList();
    await preferences.setStringList(_todosKey, encoded);
  }

  Future<int> nextId() async {
    final preferences = await SharedPreferences.getInstance();
    final nextId = preferences.getInt(_nextIdKey) ?? 1;
    await preferences.setInt(_nextIdKey, nextId + 1);
    return nextId;
  }
}

class ReminderNotificationService {
  ReminderNotificationService._();

  static final ReminderNotificationService instance =
      ReminderNotificationService._();

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();

  bool _initialized = false;
  bool _timezoneReady = false;

  Future<void> _ensureInitialized() async {
    if (_initialized) {
      return;
    }

    if (!kIsWeb && !_timezoneReady) {
      tz.initializeTimeZones();
      try {
        final timeZoneName = await FlutterTimezone.getLocalTimezone();
        tz.setLocalLocation(tz.getLocation(timeZoneName.identifier));
        _timezoneReady = true;
      } catch (_) {
        _timezoneReady = false;
      }
    }

    const androidSettings = AndroidInitializationSettings(
      '@mipmap/ic_launcher',
    );
    const appleSettings = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );

    await _plugin.initialize(
      settings: const InitializationSettings(
        android: androidSettings,
        iOS: appleSettings,
        macOS: appleSettings,
      ),
    );

    _initialized = true;
  }

  Future<bool> requestPermissions() async {
    if (kIsWeb) {
      return false;
    }

    await _ensureInitialized();

    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        final androidPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin
            >();
        final notificationGranted =
            await androidPlugin?.requestNotificationsPermission() ?? true;
        final exactAlarmGranted =
            await androidPlugin?.requestExactAlarmsPermission() ?? true;
        return notificationGranted && exactAlarmGranted;
      case TargetPlatform.iOS:
        final iosPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              IOSFlutterLocalNotificationsPlugin
            >();
        return await iosPlugin?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            true;
      case TargetPlatform.macOS:
        final macPlugin = _plugin
            .resolvePlatformSpecificImplementation<
              MacOSFlutterLocalNotificationsPlugin
            >();
        return await macPlugin?.requestPermissions(
              alert: true,
              badge: true,
              sound: true,
            ) ??
            true;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  Future<bool> scheduleReminder(TodoItem todo) async {
    if (kIsWeb || todo.reminderAt == null) {
      return false;
    }

    await _ensureInitialized();

    if (!_timezoneReady) {
      return false;
    }

    final reminderAt = todo.reminderAt!;
    final scheduledTime = tz.TZDateTime.from(reminderAt, tz.local);
    if (scheduledTime.isBefore(tz.TZDateTime.now(tz.local))) {
      return false;
    }

    const notificationDetails = NotificationDetails(
      android: AndroidNotificationDetails(
        'todo_reminders_channel',
        'TODO reminders',
        channelDescription: 'Scheduled notifications for TODO reminders',
        importance: Importance.max,
        priority: Priority.high,
        playSound: true,
      ),
      iOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
      macOS: DarwinNotificationDetails(
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      ),
    );

    await _plugin.zonedSchedule(
      id: todo.id,
      title: 'Reminder: ${todo.title}',
      body: 'Your TODO is due now.',
      scheduledDate: scheduledTime,
      notificationDetails: notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      payload: todo.id.toString(),
    );
    return true;
  }

  Future<int> schedulePendingReminders(Iterable<TodoItem> todos) async {
    var scheduledCount = 0;
    for (final todo in todos) {
      if (todo.isDone || todo.reminderAt == null) {
        continue;
      }

      final scheduled = await scheduleReminder(todo);
      if (scheduled) {
        scheduledCount++;
      }
    }

    return scheduledCount;
  }

  Future<void> cancelReminder(int id) async {
    if (kIsWeb) {
      return;
    }

    await _ensureInitialized();
    await _plugin.cancel(id: id);
  }
}

class _TodoDraft {
  const _TodoDraft({required this.title, required this.reminderAt});

  final String title;
  final DateTime? reminderAt;
}
