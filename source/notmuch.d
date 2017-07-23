module notmuch;

import std.string;
import std.algorithm;
import std.process;
import core.stdc.time;
import std.conv;
import std.stdio;

import derelict.notmuch;

version (DerelictNotMuch_Static) {
} else {
	shared static this() {
		DerelictNotMuch.load();
	}
}

void normal(Args...)(Args args) {
        writeln("\x1b[39;1m", args, "\x1b[0m");
}
void normalf(Args...)(Args args) {
        writeln("\x1b[39;1m", format(args), "\x1b[0m");
}

void good(Args...)(Args args) {
        writeln("\x1b[33;1m", args, "\x1b[0m");
}
void goodf(Args...)(Args args) {
        writeln("\x1b[33;1m", format(args), "\x1b[0m");
}

void warning(Args...)(Args args) {
        stderr.writeln("\x1b[31;1m", args, "\x1b[0m");
}

void warningf(Args...)(Args args) {
        stderr.writeln("\x1b[31;1m", format(args), "\x1b[0m");
}

void error(Args...)(Args args) {
        stderr.writeln("\x1b[37;41;1m", args, "\x1b[0m");
}

void errorf(Args...)(Args args) {
        stderr.writeln("\x1b[37;41;1m", format(args), "\x1b[0m");
}


class Database {
	this(string path = "") {
		if (!path.length) {

			if (auto maildir = environment.get("MAILDIR"))
				path = maildir;
			if (!path.length)
				path = environment["HOME"] ~ "/mail";
		}

		notmuch_status_t status = notmuch_database_open(path.toStringz, NOTMUCH_DATABASE_MODE_READ_WRITE, &_database);
		if (status) {
			errorf("notmuch_database_open: %s", status);
			assert(0);
		}

		notmuch_tags_t* _tags = notmuch_database_get_all_tags(_database);
		_availableTags = Tags(null, _tags);
	}

	~this() {
		_availableTags.destroy;
		notmuch_database_destroy(_database);
	}

	Threads queryThreads(ref Query query) {
		if (!query.query)
			query.query = notmuch_query_create(_database, query.queryStr.toStringz);

		notmuch_threads_t* threads;
		notmuch_status_t status = notmuch_query_search_threads_st(query.query, &threads);
		if (status)
			warningf("notmuch_query_search_threads_st: %s", status);
		return Threads(threads, ThreadsListExtractor(threads).output);
	}

	Messages queryMessages(ref Query query) {
		if (!query.query)
			query.query = notmuch_query_create(_database, query.queryStr.toStringz);

		notmuch_messages_t* messages;
		notmuch_status_t status = notmuch_query_search_messages_st(query.query, &messages);
		if (status)
			warningf("notmuch_query_search_messages_st: %s", status);
		return Messages(messages, MessagesListExtractor(messages).output);
	}

	void addMessage(string path) {
		notmuch_message_t* message;
		notmuch_status_t status = notmuch_database_add_message(_database, path.toStringz, &message);
		notmuch_message_destroy(message);

		if (status && status != NOTMUCH_STATUS_DUPLICATE_MESSAGE_ID)
			warningf("notmuch_database_add_message: %s", status);
	}

	void removeMessage(string path) {
		notmuch_status_t status = notmuch_database_remove_message(_database, path.toStringz);

		if (status && status != NOTMUCH_STATUS_DUPLICATE_MESSAGE_ID)
			warningf("notmuch_database_remove_message: %s", status);
	}

	@property string path() {
		return notmuch_database_get_path(_database).fromStringz.idup;
	}

	@property Tags availableTags() {
		return _availableTags;
	}

private:
	notmuch_database_t* _database;
	Tags _availableTags;
}

struct ListExtractor(Input, Output, alias validFun, alias nextFun, alias getFun) {
public:
	this(Input list) {
		for (; validFun(list); nextFun(list)) {
			auto tmp = getFun(list).to!Output;
			move(tmp, output[output.length++]);
		}
	}

	Output[] output;
}

struct ScopedValue(ListItem, Obj, alias destroyFun) {
	@disable this(this);

	this(Obj obj, ListItem[] list) {
		this.obj = obj;
		this.list = list;
	}

	~this() {
		destroyFun(obj);
	}

	alias list this;

	Obj obj;
	ListItem[] list;
}

alias Filenames = ScopedValue!(string, notmuch_filenames_t*, notmuch_filenames_destroy);
alias Messages = ScopedValue!(Message, notmuch_messages_t*, notmuch_messages_destroy);
alias Threads = ScopedValue!(Thread, notmuch_threads_t*, notmuch_threads_destroy);

alias FilenamesListExtractor = ListExtractor!(notmuch_filenames_t*, string, notmuch_filenames_valid,
		notmuch_filenames_move_to_next, notmuch_filenames_get);
alias MessagesListExtractor = ListExtractor!(notmuch_messages_t*, Message, notmuch_messages_valid,
		notmuch_messages_move_to_next, notmuch_messages_get);
alias ThreadsListExtractor = ListExtractor!(notmuch_threads_t*, Thread, notmuch_threads_valid,
		notmuch_threads_move_to_next, notmuch_threads_get);

struct Tag {
	string name;
}

struct Tags {
public:
	this(Message* message, notmuch_tags_t* tags) {
		this.message = message;
		if (!tags)
			return;
		for (; notmuch_tags_valid(tags); notmuch_tags_move_to_next(tags))
			_tags ~= Tag(notmuch_tags_get(tags).fromStringz.idup);

		notmuch_tags_destroy(tags);
	}

	bool has(Tag tag) {
		return !!find(_tags, tag).length;
	}

	void add(Tag tag) {
		assert(message);
		if (!tag.name)
			return warningf("Trying to add a empty %s to %s", tag, message.id);
		if (has(tag))
			return warningf("Tag (%s) already exist for '%s'", tag.name, message.id);
		else {
			_tags ~= tag;

			notmuch_status_t status = notmuch_message_add_tag(message._message, tag.name.toStringz);
			if (status)
				warningf("notmuch_message_add_tag: %s -> ", tag, status);
		}
	}

	void remove(Tag tag) {
		assert(message);
		auto tmp = _tags.remove!(t => t == tag, SwapStrategy.unstable);
		if (tmp == _tags)
			return warningf("Tag (%s) doesn't exist for '%s'", tag.name, message.id);
		else {
			notmuch_status_t status = notmuch_message_remove_tag(message._message, tag.name.toStringz);

			if (status)
				warningf("notmuch_message_remove_tag: %s -> ", tag, status);
		}
		_tags = tmp;
	}

	@property Tag[] tags() {
		return _tags;
	}

private:
	Message* message;
	Tag[] _tags;
}

struct Query {
	this(string q) {
		queryStr = q;
	}

	string queryStr;
	notmuch_query_t* query;

	~this() {
		if (query)
			notmuch_query_destroy(query);
	}
}

struct Message {
	this(notmuch_message_t* message) {
		assert(message);
		_message = message;
	}

	~this() {
		//notmuch_message_destroy(_message);
	}

	@property string id() {
		return notmuch_message_get_message_id(_message).fromStringz.idup;
	}

	@property time_t date() {
		return notmuch_message_get_date(_message);
	}

	@property Filenames filenames() {
		auto filenames = notmuch_message_get_filenames(_message);
		return Filenames(filenames, FilenamesListExtractor(filenames).output);
	}

	@property bool isMatched() {
		return notmuch_message_get_flag(_message, NOTMUCH_MESSAGE_FLAG_MATCH);
	}

	string header(string name) {
		return notmuch_message_get_header(_message, name.toStringz).fromStringz.idup;
	}

	@property Tags tags() {
		return Tags(&this, notmuch_message_get_tags(_message));
	}

	void sync() {
		notmuch_status_t status = notmuch_message_tags_to_maildir_flags(_message);
		if (status)
			warningf("notmuch_message_tags_to_maildir_flags: %s", status);
	}

	void freeze() {
		notmuch_status_t status = notmuch_message_freeze(_message);
		if (status)
			warningf("notmuch_message_freeze: %s", status);
	}

	void thaw() {
		notmuch_status_t status = notmuch_message_thaw(_message);
		if (status)
			warningf("notmuch_message_thaw: %s", status);
	}

private:
	notmuch_message_t* _message;
}

struct Thread {
public:
	this(notmuch_thread_t* thread) {
		assert(thread);
		_thread = thread;
	}

	~this() {
		//notmuch_thread_destroy(_thread);
	}

	@property string id() {
		return notmuch_thread_get_thread_id(_thread).fromStringz.idup;
	}

	@property string authors() {
		return notmuch_thread_get_authors(_thread).fromStringz.idup;
	}

	@property string subject() {
		return notmuch_thread_get_subject(_thread).fromStringz.idup;
	}

	@property int matchedMessagesCount() {
		return notmuch_thread_get_matched_messages(_thread);
	}

	@property Messages messages() {
		auto messages = notmuch_thread_get_messages(_thread);
		return Messages(messages, MessagesListExtractor(messages).output);
	}

private:
	notmuch_thread_t* _thread;
}
