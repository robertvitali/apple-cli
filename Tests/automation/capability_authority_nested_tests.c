/* Pure synthetic JSON buffers and fake clock. No filesystem, native, child,
   real clock, reset, loader, pipe or exec operations. */
#include "capability_authority_entry.h"
#include "capability_authority_nested_fixture.h"
#include <stdio.h>
#include <string.h>

static unsigned char input[CA_JSON_BYTES+1], before[CA_JSON_BYTES+1];
static size_t used;
static unsigned cases, failures, fixture_errors, clock_calls, expire_call;
static double now;
static CABudget budget;
static int fake_clock(void *state,double *value) {
    (void)state; clock_calls++;
    *value=(expire_call && clock_calls>=expire_call) ? 158.0 : now;
    return 0;
}
static void reset(void) {
    used=sizeof(valid_profile)-1;
    memcpy(input,valid_profile,used+1);
    now=101; clock_calls=0; expire_call=0;
    budget=(CABudget){100,158,100,fake_clock,NULL};
}
static void check(const char *name,int passed) {
    cases++; if(!passed) failures++;
    printf("case=%s status=%s\n",name,passed ? "pass" : "fail");
}
static int replace_once(const char *old,const char *replacement) {
    unsigned char *at=(unsigned char *)strstr((const char *)input,old);
    size_t old_size=strlen(old),new_size=strlen(replacement);
    if(!at || old_size>used || new_size>sizeof(input)-1 || used-old_size>sizeof(input)-1-new_size) {
        fixture_errors++; return 0;
    }
    size_t offset=(size_t)(at-input);
    memmove(at+new_size,at+old_size,used-offset-old_size+1);
    memcpy(at,replacement,new_size); used=used-old_size+new_size;
    return 1;
}
static int invoke(void) {
    memcpy(before,input,used);
    int status=ca_profile_preload_check(input,used,"synthetic-profile",&budget);
    if(memcmp(before,input,used)!=0) { fixture_errors++; return CA_REFUSED; }
    return status;
}
struct Mutation { const char *label,*old,*replacement; };
static const struct Mutation negatives[]={
 {"platform-extra","\"system\":\"Darwin\"","\"system\":\"Darwin\",\"extra\":0"},
 {"platform-duplicate-escaped","\"system\":\"Darwin\"","\"system\":\"Darwin\",\"syst\\u0065m\":\"Darwin\""},
 {"platform-schema-type","\"platform\":{\"schema_version\":1","\"platform\":{\"schema_version\":true"},
 {"platform-architecture","\"architecture\":\"arm64\"","\"architecture\":\"x86_64\""},
 {"platform-product-version","\"product_version\":\"26.0\"","\"product_version\":\"26\""},
 {"apple-base-assumption","selected-apple-system","unverified-system"},
 {"apple-base-image-type","\"file_type\":6","\"file_type\":2"},
 {"apple-base-path","/usr/lib/libSystem.B.dylib","/synthetic/libSystem.B.dylib"},
 {"runtime-version","\"version\":[3,9,6]","\"version\":[3,10,6]"},
 {"runtime-version-bool","\"version\":[3,9,6]","\"version\":[3,9,true]"},
 {"startup-isolation","\"isolated\":1","\"isolated\":0"},
 {"startup-optimization","\"optimize\":0","\"optimize\":1"},
 {"clock-constant","CLOCK_UPTIME_RAW","CLOCK_MONOTONIC"},
 {"clock-value","\"value\":8","\"value\":true"},
 {"reset-offset","\"getter_offset\":128","\"getter_offset\":-1"},
 {"image-reference","\"launcher\":{\"file\":\"launcher\"}","\"launcher\":{\"file\":\"missing\"}"},
 {"image-reused-file","\"launcher\":{\"file\":\"launcher\"}","\"launcher\":{\"file\":\"main\"}"},
 {"image-reused-physical","\"inode\":14","\"inode\":13"},
 {"main-architecture","\"file_type\":2,\"architecture\":\"arm64\"","\"file_type\":2,\"architecture\":\"x86_64\""},
 {"file-missing-reference","\"source\":\"subprocess-source\"","\"source\":\"missing-source\""},
 {"file-id-duplicate","\"id\":\"extension-dependency\"","\"id\":\"extension\""},
 {"file-path-nul","/synthetic/runtime/launcher","/synthetic/runtime/launch\\u0000er"},
 {"file-limit","\"file_count\":16","\"file_count\":5"},
 {"module-limit","\"module_count\":16","\"module_count\":4"},
 {"per-file-limit","\"per_file_bytes\":8192","\"per_file_bytes\":4095"},
 {"aggregate-limit","\"aggregate_file_bytes\":65536","\"aggregate_file_bytes\":24575"},
 {"zero-limit","\"code_nodes\":256","\"code_nodes\":0"},
 {"limit-fraction","\"code_nodes\":256","\"code_nodes\":256.0"},
 {"limit-nonfinite","\"code_nodes\":256","\"code_nodes\":1e999"},
 {"limit-global-integer","\"code_nodes\":256","\"code_nodes\":100000000000000000000"},
 {"external-entry-alias","\"aliases\":[]","\"aliases\":[\"__main__\"]"},
 {"alias-duplicate","\"aliases\":[]","\"aliases\":[\"time\"]"},
 {"builtin-origin","\"registry_name\":\"time\"","\"registry_name\":\"other_time\""},
 {"frozen-file-reference","\"file_alias\":null","\"file_alias\":\"missing\""},
 {"extension-dependency","\"dependencies\":[\"extension-dependency\"]","\"dependencies\":[\"extension\"]"},
 {"extension-extra","\"dependencies\":[\"extension-dependency\"]","\"dependencies\":[\"extension-dependency\"],\"extra\":0"},
 {"popen-source","\"destructor\":\"__del__\",\"source\":\"subprocess-source\"","\"destructor\":\"__del__\",\"source\":\"extension\""},
 {"popen-active","\"expected_active_count\":0","\"expected_active_count\":1"},
 {"preload-policy","stock-source-no-cache-v1","stock-cache-allowed"},
 {"preload-env-extra","\"LC_ALL\":\"C\"","\"LC_ALL\":\"C\",\"HOME\":\"/synthetic\""},
 {"preload-env-drift","\"LC_ALL\":\"C\"","\"LC_ALL\":\"other\""},
 {"preload-cache-prefix","\"pycache_prefix\":null","\"pycache_prefix\":\"/synthetic/cache\""},
 {"preload-cache-policy","\"check_hash_based_pycs\":\"default\"","\"check_hash_based_pycs\":\"never\""},
 {"cache-selected-source","\"selected_input\":\"source\"","\"selected_input\":\"cache\""},
 {"source-cache-present","\"cache\":null","\"cache\":\"extension\""},
 {"ordinary-cache-absence-missing","/synthetic/runtime/__pycache__/subprocess.cpython-39.pyc","/synthetic/runtime/__pycache__/other.cpython-39.pyc"},
 {"legacy-cache-absence-missing","/synthetic/runtime/subprocess.pyc","/synthetic/runtime/other.pyc"},
 {"directory-write-mode","\"mode\":16877","\"mode\":16895"},
 {"directory-exact-type","\"mode\":16877","\"mode\":33261"},
 {"directory-path-conflict","\"directories\":[{\"path\":\"/synthetic/runtime\"","\"directories\":[{\"path\":\"/synthetic/runtime/launcher\""},
 {"directory-missing-parent","\"directories\":[{\"path\":\"/synthetic/runtime\"","\"directories\":[{\"path\":\"/synthetic/elsewhere\""},
 {"file-absent-ancestor","\"absent_inputs\":[","\"absent_inputs\":[\"/synthetic/runtime\","},
 {"search-extra-module","\"module\":\"synthetic_extension\",\"candidates\"","\"module\":\"other_module\",\"candidates\""},
 {"search-duplicate-module","\"module\":\"synthetic_extension\",\"candidates\"","\"module\":\"subprocess\",\"candidates\""},
 {"candidate-no-selected","\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":\"subprocess-source\"","\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":null"},
 {"candidate-wrong-selected","\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":\"subprocess-source\"","\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":\"extension\""},
 {"candidate-extra-field","\"path\":\"/synthetic/runtime/subprocess.so\",\"file\":null","\"path\":\"/synthetic/runtime/subprocess.so\",\"file\":null,\"extra\":0"},
 {"candidate-outside-root","\"path\":\"/synthetic/runtime/subprocess.so\",\"file\":null","\"path\":\"/synthetic/elsewhere/subprocess.so\",\"file\":null"},
 {"candidate-duplicate-path","\"path\":\"/synthetic/runtime/subprocess.so\",\"file\":null","\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":null"}
};
static void positive_cases(void) {
    reset(); check("complete-source-no-cache",invoke()==CA_OK);
    /* Apple-base install names have the whole-input bound, not the separate
       4096-byte filesystem identity/preload path bound. */
    char install_name[4101];
    memset(install_name,'a',4100); memcpy(install_name,"/usr/lib/",9); install_name[4100]=0;
    reset(); replace_once("/usr/lib/libSystem.B.dylib",install_name);
    check("apple-install-name-over-4096",invoke()==CA_OK);
    memcpy(install_name+9,"../",3);
    reset(); replace_once("/usr/lib/libSystem.B.dylib",install_name);
    check("apple-install-name-malformed-component",invoke()==CA_REFUSED);
    reset(); replace_once("\"aliases\":[]","\"aliases\":[\"synthetic_signal_alias\"]");
    check("distinct-alias",invoke()==CA_OK);
    reset(); replace_once("\"system\":\"Darwin\"","\"syst\\u0065m\":\"Darwin\"");
    check("escaped-key-equivalence",invoke()==CA_OK);
    reset(); replace_once("\"expected_active_count\":0","\"expected_active_count\":-0");
    check("semantic-negative-zero",invoke()==CA_OK);
    reset(); replace_once("\"file_count\":16","\"file_count\":6");
    replace_once("\"module_count\":16","\"module_count\":5");
    replace_once("\"per_file_bytes\":8192","\"per_file_bytes\":4096");
    replace_once("\"aggregate_file_bytes\":65536","\"aggregate_file_bytes\":24576");
    check("exact-declared-limits",invoke()==CA_OK);
    reset(); replace_once("\"search_paths\":[\"/synthetic/runtime\"]","\"search_paths\":[\"/synthetic/runtime\",\"/synthetic/absent\"]");
    replace_once("\"absent_inputs\":[","\"absent_inputs\":[\"/synthetic/absent\",");
    check("absent-search-root",invoke()==CA_OK);
    reset(); replace_once("{\"path\":\"/synthetic/runtime/subprocess.so\",\"file\":null},{\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":\"subprocess-source\"}",
        "{\"path\":\"/synthetic/runtime/subprocess.py\",\"file\":\"subprocess-source\"},{\"path\":\"/synthetic/runtime/subprocess.so\",\"file\":null}");
    check("valid-candidate-permutation-input-preserved",invoke()==CA_OK);
    reset(); replace_once("\"modules\":[","\"modules\":[{\"name\":\"capability_schema\",\"kind\":\"source\",\"spec_name\":\"capability_schema\",\"aliases\":[],\"loader\":\"verified-package-buffer\",\"selected_input\":\"package-buffer\",\"source\":null,\"cache\":null,\"package_member\":\"capability_schema.py\"},");
    check("package-buffer-no-stock-search",invoke()==CA_OK);
}
static void relationship_cases(void) {
    reset(); replace_once("\"search_paths\":[\"/synthetic/runtime\"]","\"search_paths\":[\"/synthetic/runtime\",\"/synthetic/absent\"]");
    replace_once("\"absent_inputs\":[","\"absent_inputs\":[\"/synthetic/absent\",\"/synthetic/absent/shadow.py\",");
    replace_once("\"module\":\"subprocess\",\"candidates\":[","\"module\":\"subprocess\",\"candidates\":[{\"path\":\"/synthetic/absent/shadow.py\",\"file\":null},");
    check("absent-root-child-candidate-refused",invoke()==CA_REFUSED);
    reset(); replace_once("\"per_file_bytes\":8192","\"per_file_bytes\":67108865");
    replace_once("\"aggregate_file_bytes\":65536","\"aggregate_file_bytes\":134217728");
    replace_once("\"size\":4096","\"size\":67108865");
    check("fixed-file-ceiling-over-declared-limit",invoke()==CA_REFUSED);
    reset(); replace_once("\"per_file_bytes\":8192","\"per_file_bytes\":67108864");
    replace_once("\"aggregate_file_bytes\":65536","\"aggregate_file_bytes\":18446744073709551615");
    replace_once("\"size\":4096","\"size\":67108864");
    replace_once("\"size\":4096","\"size\":67108864");
    check("fixed-aggregate-ceiling-over-declared-limit",invoke()==CA_REFUSED);
}

/* An inactive row's nested objects are intentionally empty: only its envelope
   must pass when a different row is selected. Identities are synthetic. */
#define INACTIVE_ID "{\"path\":\"/synthetic/inactive-tool\",\"sha256\":\"1111111111111111111111111111111111111111111111111111111111111111\",\"device\":1,\"inode\":99,\"size\":1,\"mode\":33261,\"uid\":1,\"gid\":1,\"mtime_ns\":1,\"ctime_ns\":1}"
static const char inactive_prefix[] =
    "\"profiles\":[{\"id\":\"synthetic-inactive\",\"status\":\"inactive\","
    "\"platform\":{},\"runtime\":{},\"preload\":{},\"projection\":{},"
    "\"compiler_arguments\":[\"-inactive\"],\"executables\":{"
    "\"git\":" INACTIVE_ID ",\"swift\":" INACTIVE_ID
    ",\"compiler\":" INACTIVE_ID ",\"linker\":" INACTIVE_ID "}},";
#undef INACTIVE_ID
static void composition_cases(void) {
    reset(); replace_once("\"profiles\":[",inactive_prefix);
    check("non-first-selected-only-nested-validation",invoke()==CA_OK);
    reset();
    static const char later[] = ",{\"id\":\"synthetic-malformed\"}]}", tail[] = "]}";
    size_t later_size=sizeof(later)-1;
    if(used<2 || memcmp(input+used-2,tail,2)!=0 || used-2>sizeof(input)-1-later_size) {
        fixture_errors++;
    } else {
        memcpy(input+used-2,later,later_size+1);
        used=used-2+later_size;
    }
    check("malformed-later-envelope-after-selection",invoke()==CA_REFUSED);
}

static void bound_cases(void) {
    reset(); size_t original=used; memset(input+used,' ',CA_JSON_BYTES-used); used=CA_JSON_BYTES;
    check("complete-input-byte-limit",invoke()==CA_OK);
    input[CA_JSON_BYTES]=' '; used=CA_JSON_BYTES+1;
    check("complete-input-over-byte-limit",invoke()==CA_REFUSED);
    reset(); check("null-input",ca_profile_preload_check(NULL,1,"synthetic-profile",&budget)==CA_REFUSED);
    reset(); check("null-budget",ca_profile_preload_check(input,used,"synthetic-profile",NULL)==CA_REFUSED);
    reset(); check("missing-id",ca_profile_preload_check(input,used,"missing-profile",&budget)==CA_REFUSED);
    reset(); now=158; check("expired-original-budget",invoke()==CA_REFUSED);
    reset(); budget.deadline=159; check("changed-original-duration",invoke()==CA_REFUSED);
    reset(); now=99; check("backward-clock",invoke()==CA_REFUSED);
    reset(); int status=invoke(); unsigned completed_calls=clock_calls;
    check("valid-schema-consumes-original-clock",status==CA_OK && completed_calls>2 && budget.started==100 && budget.deadline==158);
    reset(); expire_call=completed_calls>2 ? completed_calls/2 : 2;
    check("deadline-during-schema-work",invoke()==CA_REFUSED && clock_calls>=expire_call);
    reset(); expire_call=completed_calls>2 ? completed_calls : 2;
    check("deadline-at-final-observed-check",invoke()==CA_REFUSED && clock_calls>=expire_call);
    (void)original;
}
int main(void) {
    positive_cases();
    for(size_t i=0;i<sizeof(negatives)/sizeof(negatives[0]);i++) {
        reset(); replace_once(negatives[i].old,negatives[i].replacement);
        check(negatives[i].label,invoke()==CA_REFUSED);
    }
    relationship_cases(); composition_cases(); bound_cases();
    printf("summary cases=%u failures=%u fixture_errors=%u\n",cases,failures,fixture_errors);
    return fixture_errors ? 2 : failures ? 1 : 0;
}
