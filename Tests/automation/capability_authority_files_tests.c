/* Private synthetic filesystem harness. argv[1] is an existing runner-owned
   canonical0700 root. No subject modules, real clock, process, pipe or exec. */
#include "capability_authority_entry.h"
#include "capability_authority_files_test_hooks.h"
#include "capability_authority_nested_fixture.h"
#include <CommonCrypto/CommonDigest.h>
#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { char path[4097]; dev_t device; ino_t inode; int active, directory; } Owned;
typedef struct {
    char case_root[4097], package[4097], runtime[4097], cache[4097];
    char member[8][4097], runtime_file[6][4097], manifest[4097];
    Owned owned[64]; size_t owned_count;
    unsigned char manifest_digest[32]; CAFileIdentity source_identity;
    int failed, action;
} Fixture;
static Fixture fixture;
static unsigned cases,failures,fixture_errors;
static unsigned char profile[CA_JSON_BYTES+1], manifest_data[65537];
static size_t profile_size;
static CABudget budget;
static double now;
static const char *const member_names[8]={"bats_evidence.py","bats_inventory.py","capability_policy.py","capability_process.py","capability_process_native.c","capability_process_profiles.json","capability_process_protocol.py","capability_schema.py"};
static const char *const member_kinds[8]={"python-source","python-source","python-source","python-source","native-source","profile-data","python-source","python-source"};
static const char *const runtime_names[6]={"extension","extension-dependency","framework","launcher","main","subprocess-source"};
static int fake_clock(void *state,double *value) { (void)state; *value=now; return 0; }
static void reset_budget(void) { now=101; budget=(CABudget){100,158,100,fake_clock,NULL}; }
static void check(const char *label,int passed) {
    cases++; if(!passed) failures++;
    printf("case=%s status=%s\n",label,passed ? "pass" : "fail");
}
static int format(char *out,size_t capacity,const char *text,...) {
    va_list args; va_start(args,text); int count=vsnprintf(out,capacity,text,args); va_end(args);
    return count>=0 && (size_t)count<capacity;
}
static int track(Fixture *f,const char *path,int directory,const struct stat *info) {
    if(f->owned_count>=64) return 0;
    Owned *entry=&f->owned[f->owned_count++];
    if(!format(entry->path,sizeof(entry->path),"%s",path)) return 0;
    entry->device=info->st_dev; entry->inode=info->st_ino;
    entry->directory=directory; entry->active=1; return 1;
}
static int make_directory(Fixture *f,const char *path) {
    if(mkdir(path,0700)) return 0;
    struct stat info;
    if(lstat(path,&info)!=0 || !track(f,path,1,&info)) { (void)rmdir(path); return 0; }
    return chmod(path,0700)==0;
}
static int write_file(Fixture *f,const char *path,const unsigned char *bytes,size_t length,mode_t mode) {
    int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0600);
    if(fd<0) return 0;
    struct stat info; int okay=fstat(fd,&info)==0;
    if(okay) okay=track(f,path,0,&info);
    if(!okay) { (void)close(fd); (void)unlink(path); return 0; }
    size_t used=0;
    while(used<length) {
        ssize_t count=write(fd,bytes+used,length-used);
        if(count<0 && errno==EINTR) continue;
        if(count<=0 || (size_t)count>length-used) { okay=0; break; }
        used+=(size_t)count;
    }
    if(fchmod(fd,mode)!=0) okay=0;
    if(close(fd)!=0) okay=0;
    return okay;
}
static int same_owned(const Owned *entry,const struct stat *info) {
    return entry->device==info->st_dev && entry->inode==info->st_ino;
}
static int remove_owned(Fixture *f,const char *path) {
    for(size_t i=f->owned_count;i>0;i--) {
        Owned *entry=&f->owned[i-1];
        if(entry->active && strcmp(entry->path,path)==0) {
            struct stat info;
            if(lstat(path,&info)!=0 || !same_owned(entry,&info)) return 0;
            if((entry->directory ? rmdir(path) : unlink(path))!=0) return 0;
            entry->active=0; return 1;
        }
    }
    return 0;
}
static int cleanup(Fixture *f) {
    int okay=1;
    for(size_t i=f->owned_count;i>0;i--) if(f->owned[i-1].active)
        if(!remove_owned(f,f->owned[i-1].path)) okay=0;
    return okay;
}
static int hash(const unsigned char *bytes,size_t length,unsigned char digest[32]) {
    return length<=CA_JSON_BYTES && CC_SHA256(bytes,(CC_LONG)length,digest)!=NULL;
}
static void hex(const unsigned char digest[32],char output[65]) {
    static const char digits[]="0123456789abcdef";
    for(size_t i=0;i<32;i++) { output[i*2]=digits[digest[i]>>4]; output[i*2+1]=digits[digest[i]&15]; }
    output[64]=0;
}
static uint64_t ns(struct timespec value) {
    return (uint64_t)value.tv_sec*UINT64_C(1000000000)+(uint64_t)value.tv_nsec;
}
static int identity_json(const char *path,const struct stat *info,const unsigned char digest[32],char *output,size_t capacity) {
    char text[65]; hex(digest,text);
    return format(output,capacity,"{\"path\":\"%s\",\"sha256\":\"%s\",\"device\":%llu,\"inode\":%llu,\"size\":%llu,\"mode\":%llu,\"uid\":%llu,\"gid\":%llu,\"mtime_ns\":%llu,\"ctime_ns\":%llu}",path,text,
        (unsigned long long)info->st_dev,(unsigned long long)info->st_ino,(unsigned long long)info->st_size,
        (unsigned long long)info->st_mode,(unsigned long long)info->st_uid,(unsigned long long)info->st_gid,
        (unsigned long long)ns(info->st_mtimespec),(unsigned long long)ns(info->st_ctimespec));
}
static int replace_once(const char *old,const char *replacement) {
    unsigned char *at=(unsigned char *)strstr((const char *)profile,old);
    size_t a=strlen(old),b=strlen(replacement);
    if(!at || a>profile_size || b>CA_JSON_BYTES || profile_size-a>CA_JSON_BYTES-b) return 0;
    size_t offset=(size_t)(at-profile);
    memmove(at+b,at+a,profile_size-offset-a+1); memcpy(at,replacement,b);
    profile_size=profile_size-a+b; return 1;
}
static int directory_json(const char *path,const struct stat *info,char *output,size_t capacity) {
    return format(output,capacity,"{\"path\":\"%s\",\"device\":%llu,\"inode\":%llu,\"mode\":%llu,\"uid\":%llu,\"gid\":%llu,\"mtime_ns\":%llu,\"ctime_ns\":%llu}",path,
        (unsigned long long)info->st_dev,(unsigned long long)info->st_ino,(unsigned long long)info->st_mode,
        (unsigned long long)info->st_uid,(unsigned long long)info->st_gid,
        (unsigned long long)ns(info->st_mtimespec),(unsigned long long)ns(info->st_ctimespec));
}
static int setup(Fixture *f,const char *parent,int variant) {
    memset(f,0,sizeof(*f));
    if(!format(f->case_root,sizeof(f->case_root),"%s/files-XXXXXX",parent) || !mkdtemp(f->case_root)) return 0;
    struct stat info;
    if(lstat(f->case_root,&info)!=0 || !track(f,f->case_root,1,&info)) { (void)rmdir(f->case_root); return 0; }
    if(!format(f->package,sizeof(f->package),"%s/package",f->case_root)
        || !format(f->runtime,sizeof(f->runtime),"%s/runtime",f->case_root)
        || !format(f->cache,sizeof(f->cache),"%s/__pycache__",f->runtime)
        || !make_directory(f,f->package) || !make_directory(f,f->runtime) || !make_directory(f,f->cache)) return 0;
    profile_size=sizeof(valid_profile)-1; memcpy(profile,valid_profile,profile_size+1);
    unsigned char digest[32]; if(!hash((const unsigned char *)"abc",3,digest)) return 0;
    for(size_t i=0;i<6;i++) {
        const char *leaf=i==5 ? "subprocess.py" : runtime_names[i];
        if(!format(f->runtime_file[i],sizeof(f->runtime_file[i]),"%s/%s",f->runtime,leaf)
            || !write_file(f,f->runtime_file[i],(const unsigned char *)"abc",3,0700)
            || lstat(f->runtime_file[i],&info)!=0) return 0;
        char old[8192],replacement[8192];
        if(!format(old,sizeof(old),"{\"path\":\"/synthetic/runtime/%s\",\"sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"device\":1,\"inode\":%zu,\"size\":4096,\"mode\":33261,\"uid\":1,\"gid\":1,\"mtime_ns\":1,\"ctime_ns\":1}",leaf,i+10)
            || !identity_json(f->runtime_file[i],&info,digest,replacement,sizeof(replacement))
            || !replace_once(old,replacement)) return 0;
        if(i==5) {
            f->source_identity=(CAFileIdentity){(uint64_t)info.st_dev,(uint64_t)info.st_ino,(uint64_t)info.st_size,
                (uint64_t)info.st_mode,(uint64_t)info.st_uid,(uint64_t)info.st_gid,ns(info.st_mtimespec),ns(info.st_ctimespec),{0}};
            memcpy(f->source_identity.sha256,digest,32);
        }
    }
    if(variant>=2 && variant<=5) {
        char extra[4097];
        if(variant==2) {
            if(!format(extra,sizeof(extra),"%s/subprocess.cpython-39.pyc",f->cache)
                || !write_file(f,extra,(const unsigned char *)"cache",5,0600)) return 0;
        } else if(variant==3) {
            if(!format(extra,sizeof(extra),"%s/opaque",f->runtime)
                || !write_file(f,extra,(const unsigned char *)"abc",3,0600)
                || !replace_once("\"absent_inputs\":[","\"absent_inputs\":[\"/synthetic/runtime/opaque/child\",")) return 0;
        } else if(variant==4) {
            if(!replace_once("\"search_paths\":[\"/synthetic/runtime\"]","\"search_paths\":[\"/synthetic/runtime\",\"/synthetic/runtime/missing-parent\"]")
                || !replace_once("\"absent_inputs\":[","\"absent_inputs\":[\"/synthetic/runtime/missing-parent\",\"/synthetic/runtime/missing-parent/child\",")) return 0;
        } else {
            if(!format(extra,sizeof(extra),"%s/indirect",f->runtime) || symlink("__pycache__",extra)) return 0;
            struct stat linked;
            if(lstat(extra,&linked)!=0 || !track(f,extra,0,&linked)) { (void)unlink(extra); return 0; }
            if(!replace_once("\"absent_inputs\":[","\"absent_inputs\":[\"/synthetic/runtime/indirect/child\",")) return 0;
        }
    }
    for(size_t i=0;i<2;i++) {
        const char *path=i ? f->cache : f->runtime;
        char old[8192],replacement[8192];
        if(lstat(path,&info)!=0 || !format(old,sizeof(old),"{\"path\":\"/synthetic/runtime%s\",\"device\":1,\"inode\":2,\"mode\":16877,\"uid\":1,\"gid\":1,\"mtime_ns\":1,\"ctime_ns\":1}",i ? "/__pycache__" : "")
            || !directory_json(path,&info,replacement,sizeof(replacement)) || !replace_once(old,replacement)) return 0;
    }
    /* Parent argument is admitted below as plain ASCII path data, without JSON
       metacharacters; this replacement never interprets arbitrary source. */
    while(strstr((const char *)profile,"/synthetic/runtime"))
        if(!replace_once("/synthetic/runtime",f->runtime)) return 0;
    if(variant==1 && !replace_once("\"policy\":\"stock-source-no-cache-v1\"","\"policy\":\"invalid\"")) return 0;
    for(size_t i=0;i<8;i++) {
        if(!format(f->member[i],sizeof(f->member[i]),"%s/%s",f->package,member_names[i])
            || !write_file(f,f->member[i],i==5 ? profile : (const unsigned char *)"",i==5 ? profile_size : 0,0600)) return 0;
    }
    size_t used=0;
    int count=snprintf((char *)manifest_data,sizeof(manifest_data),"{\"schema_version\":1,\"members\":[");
    if(count<0 || (size_t)count>=sizeof(manifest_data)) return 0;
    used=(size_t)count;
    for(size_t i=0;i<8;i++) {
        char text[65];
        if(!hash(i==5 ? profile : (const unsigned char *)"",i==5 ? profile_size : 0,digest)) return 0;
        hex(digest,text);
        count=snprintf((char *)manifest_data+used,sizeof(manifest_data)-used,"%s{\"path\":\"%s\",\"kind\":\"%s\",\"size\":%zu,\"sha256\":\"%s\"}",i ? "," : "",member_names[i],member_kinds[i],i==5 ? profile_size : 0,text);
        if(count<0 || (size_t)count>=sizeof(manifest_data)-used) return 0;
        used+=(size_t)count;
    }
    if(used>sizeof(manifest_data)-3) return 0;
    memcpy(manifest_data+used,"]}",3); used+=2;
    int ready=format(f->manifest,sizeof(f->manifest),"%s/capability_package_manifest.json",f->package)
        && write_file(f,f->manifest,manifest_data,used,0600) && hash(manifest_data,used,f->manifest_digest);
    if(!ready) return 0;
    /* Existing pure metadata gate validates the invented fixture independently
       of the new refusal stub. This is fixture setup, with its own fake clock. */
    reset_budget();
    return ca_profile_preload_check(profile,profile_size,"synthetic-profile",&budget)
        ==(variant==1 ? CA_REFUSED : CA_OK);
}

enum { ACTION_NONE, ACTION_CACHE, ACTION_MEMBER_SWAP, ACTION_ROOT_SWAP, ACTION_PARENT };
static int rename_owned(Fixture *f,const char *from,const char *to) {
    struct stat info;
    if(lstat(to,&info)==0 || errno!=ENOENT) return 0;
    size_t from_length=strlen(from),to_length=strlen(to); int found=0;
    for(size_t i=0;i<f->owned_count;i++) {
        Owned *entry=&f->owned[i];
        if(!entry->active || strncmp(entry->path,from,from_length)!=0
            || (entry->path[from_length]!=0 && entry->path[from_length]!='/')) continue;
        if(to_length+strlen(entry->path+from_length)>=sizeof(entry->path)) return 0;
        if(strcmp(entry->path,from)==0) {
            if(lstat(from,&info)!=0 || !same_owned(entry,&info)) return 0;
            found=1;
        }
    }
    if(!found || rename(from,to)!=0) return 0;
    for(size_t i=0;i<f->owned_count;i++) {
        Owned *entry=&f->owned[i];
        if(!entry->active || strncmp(entry->path,from,from_length)!=0
            || (entry->path[from_length]!=0 && entry->path[from_length]!='/')) continue;
        memmove(entry->path+to_length,entry->path+from_length,strlen(entry->path+from_length)+1);
        memcpy(entry->path,to,to_length);
    }
    return 1;
}
static void final_action(void *context) {
    Fixture *f=context; char path[4097];
    if(ca_file_test.before_final!=1) { f->failed=1; return; }
    if(f->action==ACTION_PARENT) {
        if(!format(path,sizeof(path),"%s/missing-parent",f->runtime)
            || !make_directory(f,path)) f->failed=1;
    } else if(f->action==ACTION_CACHE) {
        if(!format(path,sizeof(path),"%s/subprocess.cpython-39.pyc",f->cache)
            || !write_file(f,path,(const unsigned char *)"cache",5,0600)) f->failed=1;
    } else if(f->action==ACTION_MEMBER_SWAP) {
        if(!format(path,sizeof(path),"%s/retained-original-member",f->case_root)
            || !rename_owned(f,f->member[0],path)
            || !write_file(f,f->member[0],(const unsigned char *)"",0,0600)) f->failed=1;
    } else if(f->action==ACTION_ROOT_SWAP) {
        if(!format(path,sizeof(path),"%s/retained-original-package",f->case_root)
            || !rename_owned(f,f->package,path) || !make_directory(f,f->package)) { f->failed=1; return; }
        for(size_t i=0;i<8;i++)
            if(!write_file(f,f->member[i],i==5 ? profile : (const unsigned char *)"",i==5 ? profile_size : 0,0600)) f->failed=1;
        if(!write_file(f,f->manifest,manifest_data,strlen((const char *)manifest_data),0600)) f->failed=1;
    }
}
static int target_path(const char *path) {
    struct stat info;
    if(lstat(path,&info)!=0) return 0;
    ca_file_test.device=(uint64_t)info.st_dev; ca_file_test.inode=(uint64_t)info.st_ino;
    return 1;
}
static int watch_runtime(Fixture *f) {
    for(size_t i=0;i<8;i++) {
        struct stat info;
        const char *path=i<6 ? f->runtime_file[i] : i==6 ? f->runtime : f->cache;
        if(lstat(path,&info)!=0) return 0;
        ca_file_test.runtime_devices[i]=(uint64_t)info.st_dev;
        ca_file_test.runtime_inodes[i]=(uint64_t)info.st_ino;
    }
    ca_file_test.runtime_count=8; return 1;
}
static int link_owned(Fixture *f,const char *source) {
    char path[4097]; struct stat info;
    if(!format(path,sizeof(path),"%s/extra-hardlink",f->case_root) || link(source,path)) return 0;
    if(lstat(path,&info)!=0 || !track(f,path,0,&info)) { (void)unlink(path); return 0; }
    return 1;
}
enum {
    CASE_VALID, CASE_ABSENT_PARENT, CASE_BAD_DIGEST, CASE_ROOT_MODE,
    CASE_MEMBER_MODE, CASE_MANIFEST_MODE, CASE_ROOT_OWNER, CASE_MEMBER_OWNER,
    CASE_MANIFEST_OWNER, CASE_MEMBER_HARDLINK, CASE_MANIFEST_HARDLINK,
    CASE_MISSING_MEMBER, CASE_EXTRA_MEMBER, CASE_HIDDEN_MEMBER, CASE_MEMBER_LINK,
    CASE_CACHE_EXISTS, CASE_NONDIR_PARENT, CASE_SYMLINK_PARENT,
    CASE_BAD_METADATA, CASE_ACCESS_ERROR, CASE_DIRECTORY_DRIFT, CASE_READ_ERROR,
    CASE_CLOSE_ERROR, CASE_READDIR_ERROR, CASE_FDOPENDIR_ERROR, CASE_CLOSEDIR_ERROR,
    CASE_EXPIRED, CASE_READ_LATE, CASE_CLOSE_LATE, CASE_FINAL_LATE,
    CASE_FINAL_CACHE, CASE_FINAL_MEMBER_SWAP, CASE_FINAL_ROOT_SWAP, CASE_FINAL_PARENT, CASE_COUNT
};
static const char *const labels[CASE_COUNT]={
    "complete-package-zero-members", "missing-parent-remains-absent", "wrong-external-digest", "package-root-mode",
    "package-member-write-mode", "manifest-write-mode", "package-root-owner", "package-member-owner",
    "manifest-owner", "package-member-hardlink", "manifest-hardlink",
    "missing-package-member", "extra-package-member", "dot-prefixed-extra-member", "linked-package-member",
    "existing-cache-refused", "nondirectory-absence-parent", "symlinked-absence-parent",
    "invalid-metadata-before-runtime-observation", "access-error-is-not-absence", "declared-directory-drift", "runtime-read-error",
    "runtime-close-uncertainty", "enumeration-error-is-not-eof", "fdopendir-failure-raw-owner", "closedir-consumed-on-error",
    "expired-before-files", "deadline-after-read", "deadline-after-close", "deadline-before-final-pass",
    "cache-appears-before-final", "same-byte-member-replacement", "same-byte-package-replacement", "missing-parent-appears-before-final"
};
static void expire_final(void *context) { (void)context; now=158; }
static void file_case(const char *parent,int scenario) {
    Fixture *f=&fixture;
    int variant=scenario==CASE_BAD_METADATA ? 1 : scenario==CASE_CACHE_EXISTS ? 2
        : scenario==CASE_NONDIR_PARENT ? 3 : (scenario==CASE_ABSENT_PARENT || scenario==CASE_FINAL_PARENT) ? 4
        : scenario==CASE_SYMLINK_PARENT ? 5 : 0;
    if(!setup(f,parent,variant)) { fixture_errors++; if(!cleanup(f)) fixture_errors++; return; }
    ca_files_test_reset(); reset_budget(); ca_file_test.clock_value=&now;
    ca_file_test.final_action=final_action; ca_file_test.action_context=f;
    if(!watch_runtime(f) || !target_path(f->runtime_file[5])) {
        fixture_errors++;
        if(!ca_files_test_finish()) fixture_errors++;
        if(!cleanup(f)) fixture_errors++;
        return;
    }
    int setup_ok=1,needs_fault=0,needs_final=0;
    char extra[4097];
    switch(scenario) {
        case CASE_BAD_DIGEST: f->manifest_digest[0]^=1; break;
        case CASE_ROOT_MODE: setup_ok=chmod(f->package,0755)==0; break;
        case CASE_MEMBER_MODE: setup_ok=chmod(f->member[0],0662)==0; break;
        case CASE_MANIFEST_MODE: setup_ok=chmod(f->manifest,0662)==0; break;
        case CASE_ROOT_OWNER: setup_ok=target_path(f->package); ca_file_test.fault=FT_WRONG_UID; needs_fault=1; break;
        case CASE_MEMBER_OWNER: setup_ok=target_path(f->member[0]); ca_file_test.fault=FT_WRONG_UID; needs_fault=1; break;
        case CASE_MANIFEST_OWNER: setup_ok=target_path(f->manifest); ca_file_test.fault=FT_WRONG_UID; needs_fault=1; break;
        case CASE_MEMBER_HARDLINK: setup_ok=link_owned(f,f->member[0]); break;
        case CASE_MANIFEST_HARDLINK: setup_ok=link_owned(f,f->manifest); break;
        case CASE_MISSING_MEMBER: setup_ok=remove_owned(f,f->member[0]); break;
        case CASE_EXTRA_MEMBER: case CASE_HIDDEN_MEMBER:
            setup_ok=format(extra,sizeof(extra),"%s/%s",f->package,scenario==CASE_HIDDEN_MEMBER ? ".hidden" : "extra")
                && write_file(f,extra,(const unsigned char *)"",0,0600); break;
        case CASE_MEMBER_LINK: {
            struct stat info;
            setup_ok=remove_owned(f,f->member[0]) && symlink(member_names[1],f->member[0])==0;
            if(setup_ok && (lstat(f->member[0],&info)!=0 || !track(f,f->member[0],0,&info))) {
                if(unlink(f->member[0])!=0) f->failed=1;
                setup_ok=0;
            }
            break;
        }
        case CASE_ACCESS_ERROR:
            setup_ok=target_path(f->runtime); ca_file_test.denied_component="extension.py";
            ca_file_test.fault=FT_ACCESS_ERROR; needs_fault=1; break;
        case CASE_DIRECTORY_DRIFT: setup_ok=chmod(f->cache,0755)==0; break;
        case CASE_READ_ERROR: ca_file_test.fault=FT_READ_ERROR; needs_fault=1; break;
        case CASE_CLOSE_ERROR: ca_file_test.fault=FT_CLOSE_UNCERTAIN; needs_fault=1; break;
        case CASE_READDIR_ERROR: ca_file_test.fault=FT_READDIR_ERROR; needs_fault=1; break;
        case CASE_FDOPENDIR_ERROR: ca_file_test.fault=FT_FDOPENDIR_ERROR; needs_fault=1; break;
        case CASE_CLOSEDIR_ERROR: ca_file_test.fault=FT_CLOSEDIR_UNCERTAIN; needs_fault=1; break;
        case CASE_EXPIRED: now=158; break;
        case CASE_READ_LATE: ca_file_test.fault=FT_READ_LATE; needs_fault=1; break;
        case CASE_CLOSE_LATE: ca_file_test.fault=FT_CLOSE_LATE; needs_fault=1; break;
        case CASE_FINAL_LATE: ca_file_test.final_action=expire_final; needs_final=1; break;
        case CASE_FINAL_CACHE: f->action=ACTION_CACHE; needs_final=1; break;
        case CASE_FINAL_MEMBER_SWAP: f->action=ACTION_MEMBER_SWAP; needs_final=1; break;
        case CASE_FINAL_ROOT_SWAP: f->action=ACTION_ROOT_SWAP; needs_final=1; break;
        case CASE_FINAL_PARENT: f->action=ACTION_PARENT; needs_final=1; break;
        default: break;
    }
    if(!setup_ok) { fixture_errors++; if(!cleanup(f)) fixture_errors++; return; }
    int status=ca_preload_files_check(f->package,f->manifest_digest,"synthetic-profile",&budget);
    int okay=status==((scenario==CASE_VALID || scenario==CASE_ABSENT_PARENT) ? CA_OK : CA_REFUSED);
    if(needs_fault && !ca_file_test.fired) okay=0;
    if(needs_final && ca_file_test.before_final!=1) okay=0;
    if(scenario==CASE_VALID && (ca_file_test.runtime_observations==0 || ca_file_test.before_final!=1)) okay=0;
    if(scenario==CASE_BAD_METADATA && ca_file_test.runtime_observations!=0) okay=0;
    if(scenario==CASE_EXPIRED && ca_file_test.open_attempts!=0) okay=0;
    if(scenario==CASE_FINAL_MEMBER_SWAP || scenario==CASE_FINAL_ROOT_SWAP || scenario==CASE_FINAL_CACHE || scenario==CASE_FINAL_PARENT) {
        /* Both originals and replacements belong to this synthetic run. The
           predicate must leave every tracked object in place for precise cleanup. */
        for(size_t i=0;i<f->owned_count;i++) if(f->owned[i].active) {
            struct stat info;
            if(lstat(f->owned[i].path,&info)!=0 || !same_owned(&f->owned[i],&info)) okay=0;
        }
    }
    if(!ca_files_test_finish()) okay=0;
    if(f->failed) fixture_errors++;
    check(labels[scenario],okay && !f->failed);
    if(!cleanup(f)) fixture_errors++;
}
static void shared_reader_cases(const char *parent) {
    Fixture *f=&fixture;
    if(!setup(f,parent,0)) { fixture_errors++; if(!cleanup(f)) fixture_errors++; return; }
    const int faults[]={FT_NONE,FT_READ_ERROR,FT_CLOSE_UNCERTAIN,FT_READ_LATE,FT_CLOSE_LATE};
    const char *const names[]={"shared-reader-positive","shared-reader-read-error","shared-reader-consumed-close","shared-reader-read-deadline","shared-reader-close-deadline"};
    for(size_t i=0;i<5;i++) {
        ca_files_test_reset(); reset_budget(); ca_file_test.clock_value=&now;
        if(!target_path(f->runtime_file[5])) { fixture_errors++; break; }
        ca_file_test.fault=faults[i]; unsigned char output[8]; size_t written=0;
        int status=ca_read_verified_file(f->runtime_file[5],&f->source_identity,output,sizeof(output),&written,&budget);
        int okay=i==0 ? status==CA_OK && written==3 && memcmp(output,"abc",3)==0
            : status==CA_REFUSED && ca_file_test.fired>0;
        if(!ca_files_test_finish()) okay=0;
        check(names[i],okay);
    }
    if(!cleanup(f)) fixture_errors++;
}
int main(int argc,char **argv) {
    char canonical[4097]; struct stat root;
    if(argc!=2 || strnlen(argv[1],3501)>3500 || !realpath(argv[1],canonical) || strcmp(canonical,argv[1])!=0
        || strlen(canonical)>3500 || strstr(canonical,"/synthetic/runtime")
        || lstat(canonical,&root)!=0 || !S_ISDIR(root.st_mode)
        || root.st_uid!=getuid() || (root.st_mode&0777)!=0700) return 2;
    for(size_t i=0;canonical[i];i++)
        if((unsigned char)canonical[i]<32 || (unsigned char)canonical[i]>126 || canonical[i]=='"' || canonical[i]=='\\') return 2;
    shared_reader_cases(canonical);
    for(int i=0;i<CASE_COUNT;i++) file_case(canonical,i);
    printf("summary cases=%u failures=%u fixture_errors=%u\n",cases,failures,fixture_errors);
    return fixture_errors ? 2 : failures ? 1 : 0;
}
