/* Fixed synthetic buffers and fake clock only: no files, descriptors or launch. */
#include "capability_authority_entry.h"
#include <CommonCrypto/CommonDigest.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

static unsigned char input[CA_JSON_BYTES + 1];
static size_t used;
static unsigned cases, failures, fixture_errors;
static double now, step;
static unsigned clock_calls;
static CABudget budget;
static const char zero_digest[] = "0000000000000000000000000000000000000000000000000000000000000000";
static const char *const names[8] = {
    "bats_evidence.py", "bats_inventory.py", "capability_policy.py", "capability_process.py",
    "capability_process_native.c", "capability_process_profiles.json",
    "capability_process_protocol.py", "capability_schema.py"
};
static const char *const kinds[8] = {
    "python-source", "python-source", "python-source", "python-source",
    "native-source", "profile-data", "python-source", "python-source"
};

static int fake_clock(void *state, double *value) {
    (void)state; clock_calls++; *value = now; now += step; return 0;
}
static void reset_budget(void) {
    now = 101; step = 0; clock_calls = 0;
    budget = (CABudget){100,158,100,fake_clock,NULL};
}
static void check(const char *label, int passed) {
    cases++; if (!passed) failures++;
    printf("case=%s status=%s\n",label,passed ? "pass" : "fail");
}
static void begin(void) { used = 0; input[0] = 0; }
static void append(const char *format, ...) {
    if (fixture_errors) return;
    if (used >= sizeof(input)) { fixture_errors++; return; }
    va_list args; va_start(args,format);
    int amount = vsnprintf((char *)input + used,sizeof(input) - used,format,args);
    va_end(args);
    if (amount < 0 || (size_t)amount >= sizeof(input) - used) {
        fixture_errors++; input[sizeof(input)-1]=0; return;
    }
    used += (size_t)amount;
}
static void replace_once(const char *old, const char *replacement) {
    if (fixture_errors) return;
    unsigned char *at = (unsigned char *)strstr((const char *)input,old);
    size_t old_size = strlen(old), new_size = strlen(replacement);
    if (!at || new_size > sizeof(input)-1 || used-old_size > sizeof(input)-1-new_size) {
        fixture_errors++; return;
    }
    size_t offset = (size_t)(at-input);
    memmove(at+new_size,at+old_size,used-offset-old_size+1);
    memcpy(at,replacement,new_size); used=used-old_size+new_size;
}
static int all_byte(const void *buffer,size_t length,unsigned char byte) {
    const unsigned char *p=buffer;
    for (size_t i=0;i<length;i++) if(p[i]!=byte) return 0;
    return 1;
}

static void manifest(unsigned count) {
    begin(); append("{\"schema_version\":1,\"members\":[");
    for(unsigned i=0;i<count;i++) append("%s{\"path\":\"%s\",\"kind\":\"%s\",\"size\":%u,\"sha256\":\"%s\"}",
        i ? "," : "",names[i%8],kinds[i%8],i+1,zero_digest);
    append("]}");
}
static int decode_manifest(CAManifest *output) {
    unsigned char expected[32];
    if(!CC_SHA256(input,(CC_LONG)used,expected)) { fixture_errors++; return CA_REFUSED; }
    return ca_manifest_decode(input,used,expected,output,&budget);
}

static void manifest_cases(void) {
    CAManifest output;
    manifest(8); reset_budget();
    int status=decode_manifest(&output), valid=status==CA_OK;
    if(valid) for(unsigned i=0;i<8;i++)
        if(output.members[i].size!=i+1 || !all_byte(output.members[i].sha256,32,0)) valid=0;
    check("manifest-exact-eight",valid);
    if(status==CA_OK) { input[0]='['; valid=output.members[0].size==1; }
    else valid=0;
    check("manifest-detached-records",valid);
    manifest(8); unsigned char wrong[32];
    if(!CC_SHA256(input,(CC_LONG)used,wrong)) { fixture_errors++; memset(wrong,0,sizeof(wrong)); }
    wrong[0]^=1; reset_budget(); memset(&output,0xa5,sizeof(output));
    check("manifest-external-digest-refusal",ca_manifest_decode(input,used,wrong,&output,&budget)==CA_REFUSED
          && all_byte(&output,sizeof(output),0xa5));
    const char *old_values[]={"\"schema_version\":1","\"schema_version\":1","\"schema_version\":1",
        "\"members\":[","\"path\":\"bats_evidence.py\"","\"kind\":\"python-source\"",
        "\"size\":1,","\"size\":1,","\"size\":1,","\"size\":1,",
        "\"path\":\"bats_inventory.py\"","\"path\":\"bats_evidence.py\""};
    const char *new_values[]={"\"schema_version\":true","\"schema_version\":2","\"schema_version\":1,\"extra\":0",
        "\"members\":{},\"unused\":[","\"path\":\"../bats_evidence.py\"","\"kind\":\"native-source\"",
        "\"size\":1048577,","\"size\":-1,","\"size\":1.0,","\"size\":true,",
        "\"path\":\"bats_evidence.py\"","\"path\":\"capability_package_manifest.json\""};
    int refused=1;
    for(size_t i=0;i<sizeof(old_values)/sizeof(old_values[0]);i++) {
        manifest(8); replace_once(old_values[i],new_values[i]); reset_budget();
        if(decode_manifest(&output)!=CA_REFUSED) refused=0;
    }
    check("manifest-schema-and-member-refusals",refused);
    manifest(7); reset_budget(); refused=decode_manifest(&output)==CA_REFUSED;
    manifest(9); reset_budget(); if(decode_manifest(&output)!=CA_REFUSED) refused=0;
    check("manifest-cardinality",refused);
    manifest(8); replace_once("bats_evidence.py","temporary-name.py");
    replace_once("bats_inventory.py","bats_evidence.py"); replace_once("temporary-name.py","bats_inventory.py");
    reset_budget(); check("manifest-sorted-order",decode_manifest(&output)==CA_REFUSED);
    manifest(8); replace_once("\"size\":1,","\"size\":0,"); reset_budget();
    check("manifest-zero-byte-member",decode_manifest(&output)==CA_OK && output.members[0].size==0);
    manifest(8);
    for(unsigned i=1;i<=8;i++) {
        char old[32]; int size=snprintf(old,sizeof(old),"\"size\":%u,",i);
        if(size<0 || size>=(int)sizeof(old)) { fixture_errors++; break; }
        replace_once(old,"\"size\":1048576,");
    }
    reset_budget(); check("manifest-full-member-byte-bound",decode_manifest(&output)==CA_OK
                          && output.members[0].size==1048576 && output.members[7].size==1048576);
    manifest(8); replace_once("{\"schema_version\":1,\"members\":[","{\"members\":[");
    replace_once("]}","],\"schema_version\":1}"); reset_budget();
    check("manifest-object-key-order-independent",decode_manifest(&output)==CA_OK);
    manifest(8); replace_once(zero_digest,"000000000000000000000000000000000000000000000000000000000000000A");
    reset_budget(); check("manifest-lowercase-digest",decode_manifest(&output)==CA_REFUSED);
    manifest(8); replace_once("\"size\":1,","\"size\":1,\"size\":1,"); reset_budget();
    check("manifest-duplicate-key",decode_manifest(&output)==CA_REFUSED);
    unsigned char tiny=0, digest[32]={0}; reset_budget(); memset(&output,0xa5,sizeof(output));
    check("manifest-bound-before-read",ca_manifest_decode(&tiny,65537,digest,&output,&budget)==CA_REFUSED
          && all_byte(&output,sizeof(output),0xa5));
    manifest(8); reset_budget(); now=158;
    check("manifest-expired-original-budget",decode_manifest(&output)==CA_REFUSED);
    manifest(8); reset_budget(); step=60;
    check("manifest-late-processing",decode_manifest(&output)==CA_REFUSED && clock_calls>=2);
}

static void append_identity(const char *path) {
    append("{\"path\":\"%s\",\"sha256\":\"%s\",\"device\":1,\"inode\":2,\"size\":3,"
           "\"mode\":33261,\"uid\":1,\"gid\":1,\"mtime_ns\":1,\"ctime_ns\":1}",path,zero_digest);
}
static void identity(void) { begin(); append_identity("/synthetic/tool"); }
static void identity_cases(void) {
    CAPathIdentity output;
    identity(); reset_budget(); int status=ca_file_identity_decode(input,used,1,&output,&budget);
    check("identity-exact-fields",status==CA_OK && strcmp(output.path,"/synthetic/tool")==0
          && output.identity.mode==33261 && output.identity.size==3
          && output.identity.device==1 && output.identity.inode==2
          && output.identity.uid==1 && output.identity.gid==1
          && output.identity.mtime_ns==1 && output.identity.ctime_ns==1
          && all_byte(output.identity.sha256,32,0));
    identity(); replace_once("\"mode\":33261","\"mode\":33024"); reset_budget();
    check("identity-regular-nonexecutable",ca_file_identity_decode(input,used,0,&output,&budget)==CA_OK);
    reset_budget(); check("identity-required-execute",ca_file_identity_decode(input,used,1,&output,&budget)==CA_REFUSED);
    identity(); replace_once("\"size\":3","\"size\":18446744073709551615"); reset_budget();
    check("identity-exact-uint64-domain",ca_file_identity_decode(input,used,0,&output,&budget)==CA_OK
          && output.identity.size==UINT64_MAX);
    const char *old_values[]={"\"mode\":33261","\"uid\":1","\"size\":3","\"gid\":1",
        "\"inode\":2","\"device\":1","\"ctime_ns\":1","\"mtime_ns\":1",
        "/synthetic/tool","/synthetic/tool","/synthetic/tool","\"uid\":1"};
    const char *new_values[]={"\"mode\":16877","\"uid\":true","\"size\":-1","\"gid\":1.0",
        "\"inode\":18446744073709551616","\"device\":1e0","\"ctime_ns\":null","\"mtime_ns\":\"1\"",
        "synthetic/tool","/synthetic/../tool","/synthetic/a\\u0000b","\"uid\":1,\"extra\":0"};
    int refused=1;
    for(size_t i=0;i<sizeof(old_values)/sizeof(old_values[0]);i++) {
        identity(); replace_once(old_values[i],new_values[i]); reset_budget();
        if(ca_file_identity_decode(input,used,0,&output,&budget)!=CA_REFUSED) refused=0;
    }
    check("identity-exact-types-path-and-field-refusals",refused);
    identity(); replace_once("/synthetic/tool","/synthetic/a\\tb"); reset_budget();
    check("identity-tab-component",ca_file_identity_decode(input,used,0,&output,&budget)==CA_OK
          && strcmp(output.path,"/synthetic/a\tb")==0);
    char long_path[4098]; memset(long_path,'a',sizeof(long_path)); long_path[0]='/'; long_path[4096]=0;
    begin(); append_identity(long_path); reset_budget();
    check("identity-path-byte-bound-positive",ca_file_identity_decode(input,used,0,&output,&budget)==CA_OK
          && strlen(output.path)==4096);
    long_path[4096]='a'; long_path[4097]=0;
    begin(); append_identity(long_path); reset_budget();
    check("identity-path-byte-bound-refusal",ca_file_identity_decode(input,used,0,&output,&budget)==CA_REFUSED);
    identity(); reset_budget(); memset(&output,0xa5,sizeof(output));
    check("identity-closed-execute-mode",ca_file_identity_decode(input,used,2,&output,&budget)==CA_REFUSED
          && all_byte(&output,sizeof(output),0xa5));
    unsigned char tiny=0; reset_budget();
    check("identity-bound-before-read",ca_file_identity_decode(&tiny,CA_JSON_BYTES+1,0,&output,&budget)==CA_REFUSED);
    identity(); reset_budget(); step=60;
    check("identity-late-processing",ca_file_identity_decode(input,used,0,&output,&budget)==CA_REFUSED && clock_calls>=2);
}

static void profile_row(const char *id,const char *state) {
    append("{\"id\":\"%s\",\"status\":\"%s\",\"platform\":{},\"runtime\":{},\"preload\":{},\"projection\":{},"
           "\"compiler_arguments\":[\"clang\",\"-fixed\"],\"executables\":{",id,state);
    const char *const tools[]={"git","swift","compiler","linker"};
    for(unsigned i=0;i<4;i++) {
        char path[64]; int size=snprintf(path,sizeof(path),"/synthetic/%s",tools[i]);
        if(size<0 || size>=(int)sizeof(path)) { fixture_errors++; return; }
        append("%s\"%s\":",i ? "," : "",tools[i]); append_identity(path);
    }
    append("}}");
}
static void registry(unsigned count,int duplicate) {
    begin(); append("{\"schema_version\":1,\"profiles\":[");
    for(unsigned i=0;i<count;i++) {
        char id[64]; int size=snprintf(id,sizeof(id),"synthetic-%u",duplicate ? 0 : i);
        if(size<0 || size>=(int)sizeof(id)) { fixture_errors++; return; }
        if(i) append(",");
        profile_row(id,"qualified");
    }
    append("]}");
}
static int valid_span(CAUnvalidatedJsonSpan span,const char *expected) {
    size_t length=strlen(expected);
    return span.start<=span.end && span.end<=used && span.end-span.start==length
        && memcmp(input+span.start,expected,length)==0;
}
static int select_profile(CAProfileEnvelope *output) {
    return ca_profile_envelope_decode(input,used,"synthetic-0",output,&budget);
}
static void compiler_arguments(unsigned count,size_t argument_size) {
    registry(1,0);
    unsigned char *at=(unsigned char *)strstr((const char *)input,"[\"clang\",\"-fixed\"]");
    static const size_t old_size=sizeof("[\"clang\",\"-fixed\"]")-1;
    char suffix[8192],argument[4098];
    if(!at || argument_size>=sizeof(argument)) { fixture_errors++; return; }
    size_t offset=(size_t)(at-input),suffix_size=used-offset-old_size;
    if(suffix_size>=sizeof(suffix)) { fixture_errors++; return; }
    memcpy(suffix,at+old_size,suffix_size+1);
    memset(argument,'a',argument_size); argument[argument_size]=0;
    used=offset; input[used]=0; append("[");
    for(unsigned i=0;i<count;i++) append("%s\"%s\"",i ? "," : "",argument);
    append("]%s",suffix);
}
static void profile_cases(void) {
    CAProfileEnvelope output;
    registry(1,0); reset_budget(); int status=select_profile(&output);
    check("profile-envelope-spans-only",status==CA_OK && valid_span(output.platform,"{}")
          && valid_span(output.runtime,"{}") && valid_span(output.preload,"{}")
          && valid_span(output.projection,"{}") && valid_span(output.compiler_arguments,"[\"clang\",\"-fixed\"]"));
    check("profile-executable-records",status==CA_OK
          && strcmp(output.tools[CA_TOOL_GIT].path,"/synthetic/git")==0
          && strcmp(output.tools[CA_TOOL_SWIFT].path,"/synthetic/swift")==0
          && strcmp(output.tools[CA_TOOL_COMPILER].path,"/synthetic/compiler")==0
          && strcmp(output.tools[CA_TOOL_LINKER].path,"/synthetic/linker")==0);
    registry(16,0); reset_budget(); check("profile-sixteen-rows",select_profile(&output)==CA_OK);
    registry(17,0); reset_budget(); check("profile-row-bound",select_profile(&output)==CA_REFUSED);
    registry(2,1); reset_budget(); check("profile-duplicate-id",select_profile(&output)==CA_REFUSED);
    registry(0,0); reset_budget(); check("profile-missing-selection",select_profile(&output)==CA_REFUSED);
    registry(2,0); reset_budget();
    check("profile-nonempty-missing-selection",ca_profile_envelope_decode(input,used,"synthetic-absent",&output,&budget)==CA_REFUSED);
    registry(2,0);
    /* Change only the first row; the selected second row must remain distinct. */
    replace_once("/synthetic/git","/synthetic/first-git");
    replace_once("\"projection\":{}","\"projection\":{\"synthetic\":1}");
    reset_budget(); status=ca_profile_envelope_decode(input,used,"synthetic-1",&output,&budget);
    check("profile-nonfirst-selection",status==CA_OK
          && strcmp(output.tools[CA_TOOL_GIT].path,"/synthetic/git")==0
          && valid_span(output.projection,"{}"));
    registry(1,0); replace_once("qualified","inactive"); reset_budget();
    check("profile-inactive-refusal",select_profile(&output)==CA_REFUSED);
    const char *old_values[]={"\"schema_version\":1","\"schema_version\":1","qualified","synthetic-0",
        "\"platform\":{}","\"runtime\":{}","\"preload\":{}","\"projection\":{}",
        "\"compiler_arguments\":[\"clang\",\"-fixed\"]","\"compiler_arguments\":[\"clang\",\"-fixed\"]",
        "\"compiler_arguments\":[\"clang\",\"-fixed\"]","\"git\":","\"mode\":33261","\"preload\":{},"};
    const char *new_values[]={"\"schema_version\":true","\"schema_version\":1,\"extra\":0","ready","INVALID",
        "\"platform\":[]","\"runtime\":null","\"preload\":[]","\"projection\":true",
        "\"compiler_arguments\":[]","\"compiler_arguments\":[1]","\"compiler_arguments\":[\"a\\u0000b\"]",
        "\"unknown\":","\"mode\":33024",""};
    int refused=1;
    for(size_t i=0;i<sizeof(old_values)/sizeof(old_values[0]);i++) {
        registry(1,0); replace_once(old_values[i],new_values[i]); reset_budget();
        if(select_profile(&output)!=CA_REFUSED) refused=0;
    }
    check("profile-exact-envelope-refusals",refused);
    registry(2,0); replace_once("\"id\":\"synthetic-1\"","\"id\":\"synthetic-1\",\"extra\":0"); reset_budget();
    check("profile-nonselected-row-validation",select_profile(&output)==CA_REFUSED);
    compiler_arguments(256,1); reset_budget();
    check("profile-argument-count-positive",select_profile(&output)==CA_OK);
    compiler_arguments(257,1); reset_budget();
    check("profile-argument-count-refusal",select_profile(&output)==CA_REFUSED);
    compiler_arguments(1,4096); reset_budget();
    check("profile-argument-bytes-positive",select_profile(&output)==CA_OK);
    compiler_arguments(1,4097); reset_budget();
    check("profile-argument-bytes-refusal",select_profile(&output)==CA_REFUSED);
    registry(1,0); replace_once("\"status\":\"qualified\"","\"status\":\"qualified\",\"status\":\"qualified\""); reset_budget();
    check("profile-duplicate-key",select_profile(&output)==CA_REFUSED);
    registry(1,0); reset_budget(); memset(&output,0xa5,sizeof(output));
    check("profile-requested-id-validation",ca_profile_envelope_decode(input,used,"UNSET",&output,&budget)==CA_REFUSED
          && all_byte(&output,sizeof(output),0xa5));
    unsigned char tiny=0; reset_budget();
    check("profile-bound-before-read",ca_profile_envelope_decode(&tiny,CA_JSON_BYTES+1,"synthetic-0",&output,&budget)==CA_REFUSED);
    registry(1,0); reset_budget(); now=158;
    check("profile-expired-original-budget",select_profile(&output)==CA_REFUSED);
    registry(1,0); reset_budget(); step=60;
    check("profile-late-processing",select_profile(&output)==CA_REFUSED && clock_calls>=2);
}

int main(int argc,char **argv) {
    (void)argv; if(argc!=1) return 2;
    manifest_cases(); identity_cases(); profile_cases();
    if(fixture_errors) { fputs("fixture=refused\n",stderr); return 2; }
    printf("cases=%u failures=%u\n",cases,failures);
    return failures ? 1 : 0;
}
