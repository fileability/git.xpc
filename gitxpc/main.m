//  Created by Alex Gordon on 13/03/2014.

#include <xpc/xpc.h>
#include <Foundation/Foundation.h>
#import "git2.h"

#import "GTDiffPatch.h"
#import "GTDiffDelta.h"
#import "GTDiffHunk.h"
#import "GTDiffLine.h"
#import "GTDiff.h"
#import "GTTree.h"
#import "GTTreeBuilder.h"
#import "GTTreeEntry.h"
#import "ObjectiveGit.h"

static int status_callback(const char *path, unsigned int status_flags, void *payload) {
    
    // Ignore ignored files
    if ((status_flags & GIT_STATUS_IGNORED) != 0)
        return 0;
    
    xpc_object_t msg = (__bridge xpc_object_t)payload;
    xpc_dictionary_set_uint64(msg, path, status_flags);
    return 0;
}

static void get_status(xpc_connection_t conn, xpc_object_t msg, const char* path) {
    // { "files": [ { "path": "path/to/directory/file.txt", "status": "added" } ] }
    
    // TODO: Cache repos? Or would that confuse git by holding locks?
    
    NSTimeInterval t0 = [NSDate timeIntervalSinceReferenceDate];
    git_repository* repo = NULL;
    if (!git_repository_open(&repo, path) && repo) {
        git_status_foreach(repo, status_callback, (__bridge void*)msg); //CFBridgingRetain(msg));
        git_repository_free(repo);
    }
    NSTimeInterval t1 = [NSDate timeIntervalSinceReferenceDate];
    
    int64_t t_ms = (t1 - t0) * 1000;
    if (t_ms < 0)
        t_ms = 0;
    
    xpc_dictionary_set_uint64(msg, "com.chocolatapp.Chocolat.time_taken_ms", (uint64_t)t_ms);
    xpc_connection_send_message(conn, msg);
}



static int diff_file_callback(const git_diff_delta *delta, float progress, void *payload) {
    return 0;
}
static int diff_hunk_callback(const git_diff_delta *delta, const git_diff_hunk *hunk, void *payload) {
    return 0;
}
static int diff_line_callback(const git_diff_delta *delta, const git_diff_hunk *hunk, const git_diff_line *line, void *payload) {
    xpc_object_t obj = (__bridge xpc_object_t)payload;
    
    xpc_object_t info = xpc_dictionary_create(NULL, NULL, 0);
    xpc_array_append_value(obj, info);
    
#if 0
    typedef enum {
        /* These values will be sent to `git_diff_line_cb` along with the line */
        GIT_DIFF_LINE_CONTEXT   = ' ',
        GIT_DIFF_LINE_ADDITION  = '+',
        GIT_DIFF_LINE_DELETION  = '-',
        
        GIT_DIFF_LINE_CONTEXT_EOFNL = '=', /**< Both files have no LF at end */
        GIT_DIFF_LINE_ADD_EOFNL = '>',     /**< Old has no LF at end, new does */
        GIT_DIFF_LINE_DEL_EOFNL = '<',     /**< Old has LF at end, new does not */
        
        /* The following values will only be sent to a `git_diff_line_cb` when
         * the content of a diff is being formatted through `git_diff_print`.
         */
        GIT_DIFF_LINE_FILE_HDR  = 'F',
        GIT_DIFF_LINE_HUNK_HDR  = 'H',
        GIT_DIFF_LINE_BINARY    = 'B' /**< For "Binary files x and y differ" */
    } git_diff_line_t;
    
    /**
     * Structure describing a line (or data span) of a diff.
     */
    typedef struct git_diff_line git_diff_line;
    struct git_diff_line {
        char   origin;       /** A git_diff_line_t value */
        int    old_lineno;   /** Line number in old file or -1 for added line */
        int    new_lineno;   /** Line number in new file or -1 for deleted line */
        int    num_lines;    /** Number of newline characters in content */
        size_t content_len;  /** Number of bytes of data */
        git_off_t content_offset; /** Offset in the original file to the content */
        const char *content; /** Pointer to diff text, not NUL-byte terminated */
    };
#endif
    
    
//    NSLog(@"Found dif");
    xpc_dictionary_set_int64(info, "origin", (int64_t)line->origin);
    xpc_dictionary_set_int64(info, "old_lineno", (int64_t)line->old_lineno);
    xpc_dictionary_set_int64(info, "new_lineno", (int64_t)line->new_lineno);
    xpc_dictionary_set_int64(info, "num_lines", (int64_t)line->num_lines);
    
    xpc_dictionary_set_uint64(info, "num_lines", (uint64_t)line->content_len);
    xpc_dictionary_set_int64(info, "num_lines", (int64_t)line->content_offset);
    
    return 0;
}


int onGTDiffLine(const git_diff_delta *gitDelta, const git_diff_hunk *gitHunk, const git_diff_line *gitLine, void *payload){
    xpc_object_t modifications = (__bridge xpc_object_t) payload;
    GTDiffLine *line = [[GTDiffLine alloc] initWithGitLine:gitLine];
    if (line.newLineNumber < 0) {
        return 1;
    }
    
    xpc_object_t change = xpc_array_create(NULL, 0);
    xpc_array_set_int64(change, 0, (int64_t)(line.oldLineNumber));
    xpc_array_set_int64(change, 1, (int64_t)(line.newLineNumber));
    xpc_array_set_int64(change, 2, (int64_t)(line.origin));
    xpc_array_append_value(modifications, change);
    return 0;
}

static void getDiffOfFile(xpc_connection_t conn, xpc_object_t msg, xpc_object_t event, GTRepository *repo){
    NSURL *filepath = [NSURL URLWithString:@(xpc_dictionary_get_string(event, "filepath"))];
    NSData *contents = [@(xpc_dictionary_get_string(event, "buffer")) dataUsingEncoding:NSUTF8StringEncoding];
    xpc_object_t modifications = xpc_array_create(NULL, 0);
    
    GTBlob *newBlob = [GTBlob blobWithData:contents inRepository:repo error:nil];
    GTBlob *oldBlob = [GTBlob blobWithFile:filepath inRepository:repo error:nil];
    
    git_diff_blobs(oldBlob.git_blob, NULL, newBlob.git_blob, NULL, NULL, NULL, NULL, onGTDiffLine, (__bridge void*)modifications);
    
    xpc_dictionary_set_value(msg, "diff", modifications);
    xpc_connection_send_message(conn, msg);
};


static void get_diff(xpc_connection_t conn, xpc_object_t msg, xpc_object_t event) {
//static void getDiffOfFile(xpc_connection_t conn, xpc_object_t msg, xpc_object_t event, GTRepository *repo){
    NSString *repopath = @(xpc_dictionary_get_string(event, "repopath"));

    NSError* err = nil;
    NSURL* url = [NSURL fileURLWithPath:repopath isDirectory:YES];
    GTRepository* repo = [[GTRepository alloc] initWithURL:url error:&err];
    if (!repo)
        return;
    
    NSString *filepath = @(xpc_dictionary_get_string(event, "filepath"));
    const char* data = xpc_dictionary_get_string(event, "buffer");
    NSData *contents = [NSData dataWithBytesNoCopy:(void*)data length:strlen(data) freeWhenDone:NO];//[@() dataUsingEncoding:NSUTF8StringEncoding];
    
    if (!filepath || !contents) {
        xpc_connection_send_message(conn, msg);
        return;
    }
    
    xpc_object_t modifications = xpc_array_create(NULL, 0);
    
    GTBlob *newBlob = [GTBlob blobWithData:contents inRepository:repo error:nil];
    GTBlob *oldBlob = [GTBlob blobWithFile:[NSURL fileURLWithPath:filepath isDirectory:NO] inRepository:repo error:nil];
    
    git_diff_options diffopts = GIT_DIFF_OPTIONS_INIT;
    diffopts.context_lines = 0;
    
    git_diff_blobs(oldBlob.git_blob, NULL, newBlob.git_blob, NULL, &diffopts, NULL, NULL, onGTDiffLine, (__bridge void*)modifications);
    
    /*
    GTTreeBuilder *newTree = [[GTTreeBuilder alloc] initWithTree:nil error:nil];
    GTTreeBuilder *oldTree = [[GTTreeBuilder alloc] initWithTree:nil error:nil];
    GTTreeEntry *newTreeEntry = [newTree addEntryWithData:contents fileName:filepath fileMode:GTFileModeBlob error:nil];
    GTTreeEntry *oldTreeEntry = [oldTree entryWithFileName:filepath];
    
    GTDiff *diff = [GTDiff diffOldTree:oldTreeEntry.tree withNewTree:newTreeEntry.tree inRepository:repo options:@{
                                                                                                                   @"GTDiffOptionsPathSpecArrayKey": @[filepath]
                                                                                                                   } error:nil];    
    void(^onGTDiffLine)() = ^(GTDiffLine *line, BOOL *stop){
        if (!line) {
            return;
        }
        
        if (line.newLineNumber < 0) {
            return;
        }
        
        xpc_object_t change = xpc_array_create(NULL, 0);
        xpc_array_set_uint64(change, 0, line.newLineNumber);
        xpc_array_set_uint64(change, 1, line.origin);
        xpc_array_append_value(modifications, change);
    };
    
    void(^onGTDiffHunk)() = ^(GTDiffHunk *hunk, BOOL *stop){
        if (!hunk) {
            return;
        }
        
        [hunk enumerateLinesInHunk:nil usingBlock:onGTDiffLine];
    };
    
    void(^onGTDiffDelta)() = ^(GTDiffDelta *delta, BOOL *stop){
        if (!delta) {
            return;
        }
        
        GTDiffPatch *patch = [delta generatePatch:nil];
        
        if (!patch) {
            return;
        }
        
        [patch enumerateHunksUsingBlock:onGTDiffHunk];
    };
    
    if (diff) {
        [diff enumerateDeltasUsingBlock:onGTDiffDelta];
    }*/
    
    xpc_dictionary_set_value(msg, "diff", modifications);
    xpc_connection_send_message(conn, msg);
};


#if 0
static void get_diff(xpc_connection_t conn, xpc_object_t msg, const char* repopath, const char* filepath, const char* buf, size_t buflen) {
    
    git_repository* repo = NULL;
    git_repository_open(&repo, repopath);
    if (repo) {
        git_object *obj = NULL;
        git_tree_entry *subentry = NULL;
        git_blob *old_blob = NULL;
        
        // Each line is an item in the array
        xpc_object_t infos = xpc_array_create(NULL, 0);
        xpc_dictionary_set_value(msg, "lines", infos);
        
        // Load our tree
        int err = git_revparse_single(&obj, repo, "HEAD^{tree}");
        if (err) { NSLog(@"Error 1: %d", err); goto fail; }
        
        git_tree *tree = (git_tree *)obj;
        
        // Look up the tree entry
        err = git_tree_entry_bypath(&subentry, tree, filepath);
        if (err) { NSLog(@"Error 2: %d", err); goto fail; }
        
        // Convert the tree entry into an object id
        const git_oid *oid = git_tree_entry_id(subentry);
        
        // Convert the object to a blob
        err = git_blob_lookup(&old_blob, repo, oid);
        if (err) { NSLog(@"Error 3: %d", err); goto fail; }
        
//        NSLog(@"blob size: %ld", git_blob_rawsize(old_blob));
        
        // Diff
        err = git_diff_blob_to_buffer(NULL, filepath, buf, buflen, filepath, NULL,
                                      NULL, NULL, diff_line_callback, (__bridge void*)msg);
        
        if (err) { NSLog(@"Error 4: %d", err); goto fail; }
        
    fail:
        git_tree_entry_free(subentry); // caller has to free this one
        git_object_free(obj);
        git_repository_free(repo);
    }
    
    xpc_connection_send_message(conn, msg);
}
#endif

static void do_commit(xpc_connection_t conn, xpc_object_t msg, const char* path) {
    // ???
    xpc_connection_send_message(conn, msg);
}

static void handle_message(xpc_connection_t peer, xpc_object_t event) {
    const char* name = xpc_dictionary_get_string(event, "type"); assert(name != NULL);
    const char* repopath = xpc_dictionary_get_string(event, "repopath"); assert(repopath != NULL);
    xpc_connection_t reply_conn = xpc_dictionary_get_remote_connection(event); assert(reply_conn != NULL);
    xpc_object_t reply_msg = xpc_dictionary_create_reply(event); assert(reply_msg != NULL);
    
//    NSLog(@"%@", reply_msg);
    
    if (0 == strcmp("status", name)) {
        get_status(reply_conn, reply_msg, repopath);
    }
    else if (0 == strcmp("diff", name)) {
        get_diff(reply_conn, reply_msg, event);
    }
    else if (0 == strcmp("commit", name)) {
        do_commit(reply_conn, reply_msg, repopath);
    }
    else {
        assert(0 && "Unknown command");
    }
}






// --- Ignore this stuff. ---

static void gitxpc_peer_event_handler(xpc_connection_t peer, xpc_object_t event)  {
	xpc_type_t type = xpc_get_type(event);
	if (type == XPC_TYPE_ERROR) {
		if (event == XPC_ERROR_CONNECTION_INVALID) {
			// The client process on the other end of the connection has either
			// crashed or cancelled the connection. After receiving this error,
			// the connection is in an invalid state, and you do not need to
			// call xpc_connection_cancel(). Just tear down any associated state
			// here.
		} else if (event == XPC_ERROR_TERMINATION_IMMINENT) {
			// Handle per-connection termination cleanup.
		}
	} else {
		assert(type == XPC_TYPE_DICTIONARY);
        handle_message(peer, event);
	}
}

static void gitxpc_event_handler(xpc_connection_t peer)
{
	xpc_connection_set_target_queue(peer, dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    
	xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
		gitxpc_peer_event_handler(peer, event);
	});
	
	xpc_connection_resume(peer);
}

void nop_func(int x) {
    _exit(1);
}

int main(int argc, const char *argv[]) {
    // Disable crash reporter
    signal(SIGABRT, nop_func);
    signal(SIGILL, nop_func);
    signal(SIGSEGV, nop_func);
    signal(SIGFPE, nop_func);
    signal(SIGBUS, nop_func);
    signal(SIGPIPE, nop_func);
    signal(SIGSYS, nop_func);
    signal(SIGTRAP, nop_func);
    
	xpc_main(gitxpc_event_handler);
	return 0;
}
