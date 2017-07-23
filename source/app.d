import std.stdio;
import notmuch;
import std.algorithm;
import std.array;
import core.memory;
import std.format;
import std.string;
import std.regex;
import std.process;

void main() {
	updateLocalMails();
	good("mbsync -a...");
	wait(spawnShell("mbsync -a"));
	good("notmuch new...");
	wait(spawnShell("notmuch new"));
	updateNewMails();
}

void updateLocalMails() {
	good("Updating the local mail files...");
	Database db = new Database();
	scope (exit)
		db.destroy;

	moveMails(db);
}

void updateNewMails() {
	good("Updating the new mail files...");
	Database db = new Database();
	scope (exit)
		db.destroy;

	tagNewMails(db);
	removeNewTag(db);
}

void tagNewMails(Database db) {
	good("Tagging new mails...");
	struct TagRules {
		Query query;
		Tag tag;
	}

	// dfmt off
	TagRules[] rules = [
		TagRules(Query("folder:xwildn00bx/Drafts AND tag:new AND NOT tag:draft"), Tag("draft")),
		TagRules(Query("folder:xwildn00bx/Inbox AND tag:new AND NOT tag:inbox"), Tag("inbox")),
		TagRules(Query("folder:xwildn00bx/Sent AND tag:new AND NOT tag:sent"), Tag("sent")),
		TagRules(Query("folder:xwildn00bx/Spam AND tag:new AND NOT tag:spam"), Tag("spam")),
		TagRules(Query("folder:xwildn00bx/Trash AND tag:new AND NOT tag:trash"), Tag("trash"))
	];
	// dfmt on

	foreach (TagRules rule; rules) {
		normalf("Rules: %s", rule);
		foreach (ref Message message; db.queryMessages(rule.query)) {
			scope (success)
				message.sync();

			message.freeze();
			scope (exit)
				message.thaw();

			normalf("\tAdding '%s' to %s...", rule.tag, message.id);
			message.tags.add(rule.tag);
		}
	}
}

void removeNewTag(Database db) {
	good("Removing new tag...");
	auto q = Query("tag:new");
	foreach (ref Message message; db.queryMessages(q)) {
		scope (success)
			message.sync();

		message.freeze();
		scope (exit)
			message.thaw();
		message.tags.remove(Tag("new"));
		normalf("Removing 'new' from %s", message.id);
	}
}

void moveMails(Database db) {
	good("Moving mails based on tags...");
	enum Action {
		move,
		remove,
		copy
	}

	static Database* db_;
	db_ = &db;

	struct MoveRule {
		string folder;
		Query query;
		Action action;
		string moveFrom;
		string moveTo;

		static MoveRule move(string folder, Query query, string moveTo) {
			import std.path : buildPath;

			MoveRule r;
			r.folder = buildPath(db_.path(), folder);
			r.query = query;
			r.query.queryStr = format("folder:%s AND %s", folder, r.query.queryStr);
			r.action = Action.move;
			r.moveFrom = folder;
			r.moveTo = moveTo;
			return r;
		}

		static MoveRule copy(string folder, Query query, string moveTo) {
			import std.path : buildPath;

			MoveRule r;
			r.folder = buildPath(db_.path(), folder);
			r.query = query;
			r.query.queryStr = format("folder:%s AND %s", folder, r.query.queryStr);
			r.action = Action.copy;
			r.moveFrom = folder;
			r.moveTo = moveTo;
			return r;
		}

		static MoveRule remove(string folder, Query query) {
			import std.path : buildPath;

			MoveRule r;
			r.folder = buildPath(db_.path(), folder);
			r.query = query;
			r.query.queryStr = format("folder:%s AND %s", folder, r.query.queryStr);
			r.action = Action.remove;
			return r;
		}
	}

	// dfmt off
	MoveRule[] rules = [
		MoveRule.remove("xwildn00bx/Inbox", Query("NOT tag:inbox")),
		MoveRule.copy("xwildn00bx/All", Query("NOT folder:xwildn00bx/Inbox AND tag:inbox"), "xwildn00bx/Inbox"),
		MoveRule.move("xwildn00bx/All", Query("tag:trash"), "xwildn00bx/Trash"),
		MoveRule.move("xwildn00bx/All", Query("tag:spam"), "xwildn00bx/Spam"),
		MoveRule.move("xwildn00bx/Trash", Query("NOT tag:trash"), "xwildn00bx/All"),
		MoveRule.move("xwildn00bx/Spam", Query("NOT tag:spam"), "xwildn00bx/All")
	];
	// dfmt on

	//notmuch_database_remove_message

	foreach (MoveRule rule; rules) {
		goodf("Rules: %s", rule);
		foreach (ref Message message; db.queryMessages(rule.query)) {
			import std.file : exists, copy, remove;

			string path;
			// Find the path we are looking for
			foreach (filename; message.filenames)
				if (filename.startsWith(rule.folder)) {
					path = filename;
					break;
				}

			final switch (rule.action) {
			case Action.move:
				string toPath = path.replace(rule.moveFrom, rule.moveTo).replaceAll(regex(`,U=\d+`), ""); // change folder
				normalf("\tMoving '%s' to '%s'", path, toPath);
				if (exists(toPath)) {
					warningf("\t\t'%s' exist already, skipping it!", toPath);
					continue;
				}
				copy(path, toPath);
				remove(path);
				break;

			case Action.copy:
				string toPath = path.replace(rule.moveFrom, rule.moveTo).replaceAll(regex(`,U=\d+`), ""); // change folder
				normalf("\tCopying '%s' to '%s'", path, toPath);
				if (exists(toPath)) {
					warningf("\t\t'%s' exist already, skipping it!", toPath);
					continue;
				}
				copy(path, toPath);
				break;

			case Action.remove:
				normalf("\tRemoving '%s'", path);
				remove(path);
				break;
			}
		}
	}
}
