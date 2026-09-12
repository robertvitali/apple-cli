/* Private synthetic dispatcher specification. Reuse the reviewed filesystem
   builder as source, never call its renamed original main. Its real reader
   controls remain available; process-facing leaves are fake in the other TU. */
#include "capability_authority_entry.h"
#include "capability_authority_handoff_test_hooks.h"
#define main ca_existing_files_main_not_invoked
#include "capability_authority_files_tests.c"
#undef main

static char shim_path[4097], manifest_hex[65], abc_hex[65], shim_hex[65];
static unsigned char shim_bytes[65537];
static char operand_storage[4][4098];
static const char *operands[10], *expected_operands[10];
static unsigned char expected_record[64];
static unsigned mutation_calls, entry_clock_calls;
static int mutate_first_clock(void *state,double *value) {
    CABudget *target=state;
    entry_clock_calls++;
    if(entry_clock_calls==1) { target->started=101; target->deadline=159; }
    *value=101; return 0;
}

static int rewrite_profile(Fixture *f) {
    unsigned char digest[32]; size_t used=0;
    int count=snprintf((char *)manifest_data,sizeof(manifest_data),"{\"schema_version\":1,\"members\":[");
    if(count<0 || (size_t)count>=sizeof(manifest_data)) return 0;
    used=(size_t)count;
    for(size_t i=0;i<8;i++) {
        char text[65];
        if(!hash(i==5 ? profile : (const unsigned char *)"",i==5 ? profile_size : 0,digest)) return 0;
        hex(digest,text);
        count=snprintf((char *)manifest_data+used,sizeof(manifest_data)-used,
            "%s{\"path\":\"%s\",\"kind\":\"%s\",\"size\":%zu,\"sha256\":\"%s\"}",
            i ? "," : "",member_names[i],member_kinds[i],i==5 ? profile_size : 0,text);
        if(count<0 || (size_t)count>=sizeof(manifest_data)-used) return 0;
        used+=(size_t)count;
    }
    if(used>sizeof(manifest_data)-3) return 0;
    memcpy(manifest_data+used,"]}",3); used+=2;
    if(!remove_owned(f,f->member[5]) || !remove_owned(f,f->manifest)
        || !write_file(f,f->member[5],profile,profile_size,0600)
        || !write_file(f,f->manifest,manifest_data,used,0600)
        || !hash(manifest_data,used,f->manifest_digest)) return 0;
    reset_budget();
    return ca_profile_preload_check(profile,profile_size,"synthetic-profile",&budget)==CA_OK;
}
#define INACTIVE_ID "{\"path\":\"/synthetic/inactive-tool\",\"sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"device\":1,\"inode\":99,\"size\":1,\"mode\":33261,\"uid\":1,\"gid\":1,\"mtime_ns\":1,\"ctime_ns\":1}"
static const char inactive_prefix[] =
    "\"profiles\":[{\"id\":\"synthetic-inactive\",\"status\":\"inactive\","
    "\"platform\":{},\"runtime\":{},\"preload\":{},\"projection\":{},"
    "\"compiler_arguments\":[\"-inactive\"],\"executables\":{"
    "\"git\":" INACTIVE_ID ",\"swift\":" INACTIVE_ID
    ",\"compiler\":" INACTIVE_ID ",\"linker\":" INACTIVE_ID "}},";
#undef INACTIVE_ID

enum {
 H_CHECK,H_COMPARE,H_NONFIRST,H_SHIM_LIMIT,H_TOKEN_LIMIT,H_AGG_LIMIT,H_COPY,
 H_UNSET,H_BAD_MANIFEST,H_BAD_PROFILE,H_INTERPRETER_PATH,H_INTERPRETER_HASH,
 H_SHIM_HASH,H_SHIM_LINK,H_SHIM_PARENT_LINK,H_SHIM_OVERSIZE,H_BAD_METADATA,H_CACHE,
 H_COUNT,H_ORDER,H_OPERATION,H_PREFIX,H_TOKEN_OVER,H_AGG_OVER,H_NULL_TOKEN,
 H_EXPIRED,H_EXTENDED,H_BACKWARD,H_SHIM_READ_LATE,H_SHIM_CLOSE_LATE,
 H_FINAL_CACHE,H_FINAL_MEMBER,H_FINAL_SHIM,H_FINAL_LATE,
 H_PIPE,H_PIPE_LATE,H_GETFL,H_SETFL,H_GETFD,H_SETFD,H_DUP,H_DUP_LATE,H_OLD_CLOSE,
 H_SHORT,H_ZERO,H_EINTR,H_EAGAIN,H_EPIPE,H_WRITE,H_WRITE_LATE,
 H_WRITER_CLOSE,H_WRITER_CLOSE_LATE,H_CLEAR,H_CLEAR_LATE,H_EXEC,H_EXEC_LATE,
 H_STDIO,H_FIRST_CLOCK_MUTATION,H_COUNT_TOTAL
};
static const char *const handoff_labels[H_COUNT_TOTAL]={
 "fixed-check-attempt","fixed-compare-attempt","non-first-selected-launcher","shim-at-65536",
 "operand-at-4096","operands-at-16384","owned-operand-copy-at-pipe",
 "unset-authority","bad-manifest-pin","bad-profile-id","external-interpreter-path-mismatch",
 "external-interpreter-hash-mismatch","external-shim-hash-mismatch","linked-shim","linked-shim-parent",
 "shim-over-65536","bad-metadata-before-pipe","existing-cache-before-pipe",
 "wrong-operand-count","wrong-fixed-flag-order","wrong-operation","candidate-bootstrap-token",
 "operand-over-4096","operands-over-16384","null-operand",
 "expired-original-D","extended-duration","backward-clock","late-shim-read","late-shim-close",
 "cache-appears-before-final","member-replaced-before-final","same-byte-shim-replacement","late-final-check",
 "pipe-error","pipe-success-late","getfl-error","setfl-error","getfd-error","setfd-error",
 "duplicate-error","duplicate-success-late","duplicate-original-close-uncertainty",
 "short-write","zero-write","write-EINTR","write-EAGAIN","synthetic-write-EPIPE","write-error","write-success-late",
 "writer-close-uncertainty","writer-close-late","clear-cloexec-error","clear-cloexec-late",
 "exec-return-error","exec-return-late","closed-stdio-relocation","first-clock-mutates-original-budget"
};
static int configure_operands(int compare) {
    memset(operands,0,sizeof(operands)); memset(expected_operands,0,sizeof(expected_operands));
    if(!format(operand_storage[0],sizeof(operand_storage[0]),"/synthetic/candidate")
        || !format(operand_storage[1],sizeof(operand_storage[1]),"0123456789012345678901234567890123456789")
        || !format(operand_storage[2],sizeof(operand_storage[2]),"/synthetic/head")
        || !format(operand_storage[3],sizeof(operand_storage[3]),"abcdefabcdefabcdefabcdefabcdefabcdefabcd")) return 0;
    if(compare) {
        const char *values[]={"compare","--base-repository-root",operand_storage[0],"--expected-base-sha",operand_storage[1],
            "--head-repository-root",operand_storage[2],"--expected-head-sha",operand_storage[3]};
        memcpy(operands,values,sizeof(values));
    } else {
        const char *values[]={"check","--repository-root",operand_storage[0],"--expected-sha",operand_storage[1]};
        memcpy(operands,values,sizeof(values));
    }
    memcpy(expected_operands,operands,sizeof(operands)); return 1;
}
static void mutate_operands(void *context) {
    (void)context; mutation_calls++;
    /* Only source operand bytes mutate; expected strings are separate literals. */
    operand_storage[0][0]='X'; operand_storage[1][0]='X'; operands[0]="snapshot";
}
static void handoff_final_mutation(void *context) {
    Fixture *f=context; mutation_calls++;
    if(ca_file_test.before_final!=1) { f->failed=1; return; }
    if(f->action==100) {
        char retained[4097];
        if(!format(retained,sizeof(retained),"%s/original-shim",f->case_root)
            || !rename_owned(f,shim_path,retained)
            || !write_file(f,shim_path,shim_bytes,3,0600)) f->failed=1;
    } else if(f->action==101) now=158;
    else final_action(context);
}
static int record_matches(void) {
    return ca_handoff_test.record_size==64
        && memcmp(ca_handoff_test.record,expected_record,64)==0;
}
static int make_link(Fixture *f,const char *path,const char *target) {
    struct stat info;
    if(symlink(target,path)) return 0;
    if(lstat(path,&info)!=0 || !track(f,path,0,&info)) { (void)unlink(path); return 0; }
    return 1;
}
static int fault_for(int scenario) {
    static const int map[]={HT_PIPE_ERROR,HT_PIPE_LATE,HT_GETFL_ERROR,HT_SETFL_ERROR,HT_GETFD_ERROR,HT_SETFD_ERROR,
        HT_DUP_ERROR,HT_DUP_LATE,HT_OLD_CLOSE_ERROR,HT_WRITE_SHORT,HT_WRITE_ZERO,HT_WRITE_EINTR,HT_WRITE_EAGAIN,
        HT_WRITE_EPIPE,HT_WRITE_ERROR,HT_WRITE_LATE,HT_WRITER_CLOSE_ERROR,HT_WRITER_CLOSE_LATE,HT_CLEAR_ERROR,
        HT_CLEAR_LATE,HT_EXEC_ERROR,HT_EXEC_LATE};
    return scenario>=H_PIPE && scenario<=H_EXEC_LATE ? map[scenario-H_PIPE] : HT_NONE;
}
static void handoff_case(const char *parent,int scenario) {
    Fixture *f=&fixture; ca_handoff_test_reset(); ca_files_test_reset();
    int variant=scenario==H_BAD_METADATA ? 1 : scenario==H_CACHE ? 2 : 0;
    if(!setup(f,parent,variant)) {
        fixture_errors++; if(!ca_files_test_finish()) fixture_errors++;
        if(!ca_handoff_test_finish()) fixture_errors++;
        if(!cleanup(f)) fixture_errors++; return;
    }
    int ready=1; size_t shim_size=scenario==H_SHIM_LIMIT ? 65536 : scenario==H_SHIM_OVERSIZE ? 65537 : 3;
    memset(shim_bytes,'s',sizeof(shim_bytes));
    if(scenario==H_NONFIRST) ready=replace_once("\"profiles\":[",inactive_prefix) && rewrite_profile(f);
    unsigned char digest[32],binding[32];
    ready=ready && format(shim_path,sizeof(shim_path),"%s/shim.py",f->case_root)
        && write_file(f,shim_path,shim_bytes,shim_size,0600)
        && hash((const unsigned char *)"abc",3,digest);
    if(ready) hex(digest,abc_hex);
    ready=ready && hash(shim_bytes,shim_size,digest);
    if(ready) { hex(digest,shim_hex); hex(f->manifest_digest,manifest_hex); }
    CAExecutionPins pins={f->package,manifest_hex,"synthetic-profile",f->runtime_file[3],abc_hex,shim_path,shim_hex};
    int compare=scenario==H_COMPARE || scenario==H_AGG_LIMIT || scenario==H_AGG_OVER;
    size_t count=compare ? 9 : 5;
    ready=ready && configure_operands(compare);
    if(!ready) {
        fixture_errors++; if(!ca_files_test_finish()) fixture_errors++;
        if(!ca_handoff_test_finish()) fixture_errors++;
        if(!cleanup(f)) fixture_errors++; return;
    }
    /* Codec reference is computed with the real reviewed primitive and a
       separate fixture budget before the dispatcher budget starts. */
    reset_budget();
    ready=ca_authority_binding(pins.root,pins.manifest_sha256,pins.profile_id,binding,&budget)==CA_OK
        && ca_bootstrap_record(&budget,binding,expected_record)==CA_OK;
    ca_files_test_reset(); reset_budget();
    ca_file_test.clock_value=&now; ca_file_test.action_context=f;
    ca_handoff_test.clock_value=&now; ca_handoff_test.active=1;
    ca_handoff_test.expected_interpreter=pins.interpreter_path; ca_handoff_test.expected_shim=pins.shim_path;
    ca_handoff_test.expected_operands=expected_operands; ca_handoff_test.expected_count=count;
    ca_handoff_test.fault=fault_for(scenario);
    ca_handoff_test.stdio_pipe=scenario==H_STDIO || scenario==H_DUP || scenario==H_DUP_LATE || scenario==H_OLD_CLOSE;
    struct stat info;
    ready=ready && lstat(shim_path,&info)==0;
    if(ready) { ca_handoff_test.shim_device=info.st_dev; ca_handoff_test.shim_inode=info.st_ino; }
    ready=ready && lstat(f->package,&info)==0;
    if(ready) { ca_handoff_test.package_device=info.st_dev; ca_handoff_test.package_inode=info.st_ino; }
    mutation_calls=0;
    char extra[4097],linked_path[4097];
    int no_pipe=0,needs_mutation=0,needs_file_fault=0;
    switch(scenario) {
        case H_UNSET: pins.root="UNSET"; no_pipe=1; break;
        case H_BAD_MANIFEST: manifest_hex[0]=manifest_hex[0]=='0' ? '1' : '0'; no_pipe=1; break;
        case H_BAD_PROFILE: pins.profile_id="bad/profile"; no_pipe=1; break;
        case H_INTERPRETER_PATH: pins.interpreter_path=f->runtime_file[4]; no_pipe=1; break;
        case H_INTERPRETER_HASH: abc_hex[0]=abc_hex[0]=='0' ? '1' : '0'; no_pipe=1; break;
        case H_SHIM_HASH: shim_hex[0]=shim_hex[0]=='0' ? '1' : '0'; no_pipe=1; break;
        case H_SHIM_LINK:
            ready=ready && format(extra,sizeof(extra),"%s/shim-link",f->case_root) && make_link(f,extra,"shim.py");
            pins.shim_path=extra; no_pipe=1; break;
        case H_SHIM_PARENT_LINK:
            ready=ready && format(extra,sizeof(extra),"%s/linked-parent",f->case_root) && make_link(f,extra,".")
                && format(linked_path,sizeof(linked_path),"%s/shim.py",extra);
            pins.shim_path=linked_path; no_pipe=1; break;
        case H_SHIM_OVERSIZE: case H_BAD_METADATA: case H_CACHE: no_pipe=1; break;
        case H_COUNT: count=4; no_pipe=1; break;
        case H_ORDER: operands[1]="--expected-sha"; operands[3]="--repository-root"; no_pipe=1; break;
        case H_OPERATION: operands[0]="snapshot"; no_pipe=1; break;
        case H_PREFIX: operands[2]="--capability-bootstrap-fd"; no_pipe=1; break;
        case H_TOKEN_OVER: case H_TOKEN_LIMIT:
            memset(operand_storage[0],'p',scenario==H_TOKEN_OVER ? 4097 : 4096);
            operand_storage[0][scenario==H_TOKEN_OVER ? 4097 : 4096]=0;
            no_pipe=scenario==H_TOKEN_OVER; break;
        case H_AGG_LIMIT: case H_AGG_OVER: {
            size_t fixed=0; for(size_t i=0;i<9;i++) if(i!=2 && i!=4 && i!=6 && i!=8) fixed+=strlen(operands[i]);
            size_t total=scenario==H_AGG_OVER ? 16385 : 16384;
            if(fixed>total || total-fixed<3*4096 || total-fixed-3*4096>4096) { ready=0; break; }
            for(size_t i=0;i<4;i++) {
                size_t length=i<3 ? 4096 : total-fixed-3*4096;
                memset(operand_storage[i],'a',length); operand_storage[i][length]=0;
            }
            no_pipe=scenario==H_AGG_OVER; break;
        }
        case H_NULL_TOKEN: operands[2]=NULL; no_pipe=1; break;
        case H_COPY:
            expected_operands[2]="/synthetic/candidate"; expected_operands[4]="0123456789012345678901234567890123456789";
            ca_handoff_test.at_pipe=mutate_operands; needs_mutation=1; break;
        case H_FIRST_CLOCK_MUTATION:
            entry_clock_calls=0; budget.read=mutate_first_clock; budget.state=&budget; no_pipe=1; break;
        case H_EXPIRED: now=158; no_pipe=1; break;
        case H_EXTENDED: budget.deadline=159; no_pipe=1; break;
        case H_BACKWARD: now=99; no_pipe=1; break;
        case H_SHIM_READ_LATE: case H_SHIM_CLOSE_LATE:
            ready=ready && target_path(shim_path);
            ca_file_test.fault=scenario==H_SHIM_READ_LATE ? FT_READ_LATE : FT_CLOSE_LATE;
            needs_file_fault=1; no_pipe=1; break;
        case H_FINAL_CACHE: case H_FINAL_MEMBER: case H_FINAL_SHIM: case H_FINAL_LATE:
            f->action=scenario==H_FINAL_CACHE ? ACTION_CACHE : scenario==H_FINAL_MEMBER ? ACTION_MEMBER_SWAP
                : scenario==H_FINAL_SHIM ? 100 : 101;
            ca_file_test.final_action=handoff_final_mutation; needs_mutation=1; break;
        default: break;
    }
    if(!ready) {
        fixture_errors++; if(!ca_files_test_finish()) fixture_errors++;
        if(!ca_handoff_test_finish()) fixture_errors++;
        if(!cleanup(f)) fixture_errors++; return;
    }
    int result=ca_authority_dispatch(&pins,count,operands,&budget);
    int expect_exec=scenario<=H_COPY || scenario==H_STDIO || scenario==H_EXEC || scenario==H_EXEC_LATE;
    int okay=result==CA_REFUSED && ca_handoff_test.exec_calls==(unsigned)expect_exec
        && ca_handoff_test.pipe_calls<=1 && ca_handoff_test.write_calls<=1
        && budget.started==(scenario==H_FIRST_CLOCK_MUTATION ? 101 : 100)
        && budget.deadline==(scenario==H_EXTENDED || scenario==H_FIRST_CLOCK_MUTATION ? 159 : 158);
    if(scenario==H_FIRST_CLOCK_MUTATION) okay=okay && entry_clock_calls==1 && ca_file_test.open_attempts==0;
    if(no_pipe) okay=okay && ca_handoff_test.pipe_calls==0;
    if(ca_handoff_test.fault!=HT_NONE) okay=okay && ca_handoff_test.fired>0;
    if(needs_file_fault) okay=okay && ca_file_test.fired>0;
    if(needs_mutation) okay=okay && mutation_calls==1;
    if(expect_exec) okay=okay && record_matches() && ca_handoff_test.writer_closed_at_final==1;
    if(scenario==H_STDIO) okay=okay && ca_handoff_test.dup_calls==2 && ca_handoff_test.peak_live==3;
    if(scenario==H_DUP_LATE || scenario==H_OLD_CLOSE) okay=okay && ca_handoff_test.dup_calls==1
        && ca_handoff_test.peak_live==3;
    if(scenario==H_FINAL_CACHE || scenario==H_FINAL_MEMBER || scenario==H_FINAL_SHIM || scenario==H_FINAL_LATE)
        okay=okay && ca_handoff_test.writer_closed_at_final==1 && ca_handoff_test.exec_calls==0;
    /* Presence checks precede cleanup and only inspect exact owned records. */
    for(size_t i=0;i<f->owned_count;i++) if(f->owned[i].active) {
        struct stat observed;
        if(lstat(f->owned[i].path,&observed)!=0 || !same_owned(&f->owned[i],&observed)) okay=0;
    }
    int files_clean=ca_files_test_finish(),handoff_clean=ca_handoff_test_finish();
    okay=okay && files_clean && handoff_clean;
    if(f->failed) fixture_errors++;
    check(handoff_labels[scenario],okay);
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
    for(int i=0;i<H_COUNT_TOTAL;i++) handoff_case(canonical,i);
    printf("summary cases=%u failures=%u fixture_errors=%u\n",cases,failures,fixture_errors);
    return fixture_errors ? 2 : failures ? 1 : 0;
}
