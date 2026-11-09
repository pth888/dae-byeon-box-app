import 'dart:async';

import 'package:blackbox_driver_care/preview/chat_preview_data.dart';
import 'package:blackbox_driver_care/services/thread_chat_controller.dart';
import 'package:blackbox_driver_care/services/thread_chat_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/thread_chat_fakes.dart';


void main() {
  test('saving with AI paused succeeds without an error or stale retry', () async {
    final controller = ThreadChatController(PreviewThreadService(persist: (_) {}));
    addTearDown(controller.dispose);
    expect(await controller.send('과실 비율이 뭔가요?'), isTrue);
    expect(controller.state.messages.single.text, '과실 비율이 뭔가요?');
    expect(controller.state.error, isNull);
    expect(controller.state.retryText, isNull);
  });

  test('global entry is a clean general draft even after an accident', () async {
    final service = ControlledThreads();
    final controller = ThreadChatController(service);
    addTearDown(controller.dispose);
    await controller.openAccident('case-a');
    expect(controller.state.selected!.mode, 'accident');
    controller.newChat();
    expect(controller.state.selected, isNull);
    expect(controller.state.context, isNull);
    expect(controller.state.messages, isEmpty);
  });

  test('late history from A cannot replace thread B', () async {
    final service = ControlledThreads();
    final controller = ThreadChatController(service);
    addTearDown(controller.dispose);
    final old = Completer<ChatThreadDetail>();
    service.pending['a'] = old;
    final loadingA = controller.openThread(thread('a'));
    await controller.openThread(thread('b'));
    old.complete(ChatThreadDetail(thread('a'), {'case_id': 'a'}));
    await loadingA;
    expect(controller.state.selected!.id, 'b');
    expect(controller.state.context, isNull);
  });

  test('late send cannot put the previous reply in a new general draft', () async {
    final service = ControlledThreads();
    final controller = ThreadChatController(service);
    addTearDown(controller.dispose);
    service.reply = Completer<ThreadReply>();
    final sending = controller.send('hello');
    await Future<void>.delayed(Duration.zero);
    controller.newChat();
    service.reply!.complete(const ThreadReply([], true));
    await sending;
    expect(controller.state.selected, isNull);
    expect(controller.state.messages, isEmpty);
    expect(controller.state.sending, isFalse);
  });

  test('unavailable reply keeps one saved question and retry reuses its ID', () async {
    final service = ControlledThreads();
    final controller = ThreadChatController(service);
    addTearDown(controller.dispose);
    service.complete = false;
    await controller.send('hello');
    expect(controller.state.retryText, 'hello');
    final request = service.lastRequest;
    service.complete = true;
    await controller.retry();
    expect(service.lastRequest, request);
    expect(controller.state.retryText, isNull);
  });
}
