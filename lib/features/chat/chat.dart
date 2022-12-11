import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:tuple/tuple.dart';

import '../../firestore_models/chat_room.dart';
import '../../firestore_models/message.dart';
import '../../firestore_refs.dart';
import '../../repositories/chat.dart';
import '../../utils/exceptions/base.dart';
import '../../utils/uuid.dart';
import '../auth/auth.dart';
import 'chat_room_state.dart';

/// チャットルーム一覧を取得する StreamProvider。
final chatRooms = StreamProvider.autoDispose<List<ChatRoom>>(
  (ref) => ref.read(chatRepository).subscribeChatRooms(),
);

/// 指定したチャットルームの最新 1 件のメッセージを取得する Provider。
final latestMessage = Provider.autoDispose.family<Message?, String>(
  (ref, chatRoomId) => ref.watch(_latestMessages(Tuple2(chatRoomId, 1))).when(
        data: (messages) => messages.isNotEmpty ? messages.first : null,
        error: (_, __) => null,
        loading: () => null,
      ),
);

final _latestMessages = StreamProvider.autoDispose.family<List<Message>, Tuple2<String, int>>(
  (ref, tuple2) => ref.read(chatRepository).subscribeMessages(
        chatRoomId: tuple2.item1,
        queryBuilder: (q) => q.orderBy('createdAt', descending: true).limit(tuple2.item2),
      ),
);

/// ChatRoomState の操作とチャットルームページの振る舞いを記述したモデル。
final chatModel = StateNotifierProvider.autoDispose.family<Chat, ChatRoomState, String>(Chat.new);

/// ChatRoomState の操作とチャットルームページの振る舞いを記述したモデル。
class Chat extends StateNotifier<ChatRoomState> {
  Chat(this._ref, this._chatRoomId) : super(const ChatRoomState()) {
    Future<void>(() async {
      await Future.wait<void>([
        loadMore(limit: 10),
        // ChatPage に遷移直後のメッセージアイコンを意図的に見せるために最低でも 500 ms 待つ。
        Future<void>.delayed(const Duration(milliseconds: 500)),
      ]);
      endLoading();
    });
  }

  final AutoDisposeStateNotifierProviderRef<Chat, ChatRoomState> _ref;
  final String _chatRoomId;

  /// 過去のメッセージを、最後に取得した queryDocumentSnapshot 以降の
  /// limit 件だけ取得する。
  Future<void> loadMore({required int limit}) async {
    if (!state.hasMore) {
      state = state.copyWith(fetching: false);
      return;
    }
    if (state.fetching) {
      return;
    }
    state = state.copyWith(fetching: true);
    final qs = await _ref.read(chatRepository).loadMoreMessagesQuerySnapshot(
          limit: limit,
          chatRoomId: _chatRoomId,
          lastReadQueryDocumentSnapshot: state.lastReadQueryDocumentSnapshot,
        );
    final messages = qs.docs.map((qds) => qds.data()).toList();
    updatePastMessages([...state.pastMessages, ...messages]);
    updateMessages();
    state = state.copyWith(
      fetching: false,
      lastReadQueryDocumentSnapshot: qs.docs.isNotEmpty ? qs.docs.last : null,
      hasMore: qs.docs.length >= limit,
    );
  }

  /// 取得したメッセージ全体を更新する。
  void updateMessages() {
    state = state.copyWith(messages: [...state.newMessages, ...state.pastMessages]);
  }

  /// チャットルーム画面に遷移した後に新たに取得したメッセージを更新する。
  void updateNewMessages(List<Message> newMessages) {
    state = state.copyWith(newMessages: newMessages);
  }

  /// チャットルーム画面を遡って取得した過去のメッセージを更新する。
  void updatePastMessages(List<Message> pastMessages) {
    state = state.copyWith(pastMessages: pastMessages);
  }

  /// メッセージを送信する。
  Future<void> sendMessage({
    required String text,
  }) async {
    if (state.sending) {
      return;
    }
    final userId = _ref.read(userIdAsyncValue).value;
    if (userId == null) {
      throw const AppException(message: 'メッセージの送信にはログインが必要です。');
    }
    state = state.copyWith(sending: true);
    final message = Message(
      messageId: uuid,
      senderId: userId,
      content: text,
    );
    try {
      await messageRef(
        chatRoomId: _chatRoomId,
        messageId: message.messageId,
      ).set(message);
    } finally {
      state = state.copyWith(sending: false);
    }
  }

  void startLoading() {
    state = state.copyWith(loading: true);
  }

  void endLoading() {
    state = state.copyWith(loading: false);
  }

  void updateIsValid({required bool isValid}) {
    state = state.copyWith(isValid: isValid);
  }
}