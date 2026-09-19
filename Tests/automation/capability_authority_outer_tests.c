/* Synthetic outer-entry tests. No real clock, signal, pipe, exec or subject
   imports. Actual dispatcher controls use the retained intercepted C engine. */
#include "capability_authority_outer_test_api.h"
#include "capability_authority_handoff_test_hooks.h"
#include <errno.h>
#include <float.h>
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

static unsigned cases, failures, fixture_errors;
static int events[64];
static size_t event_count;
static unsigned clock_calls, dispatch_calls, diagnostic_calls, wrong_leaf;
static struct timespec readings[16];
static int read_errors[16];
static size_t reading_count;
static int real_dispatch, dispatch_return, write_behavior, check_continuing_clock;
static char **clock_env;
static char **clock_args;
static size_t expected_count;
static const char check_token[]="check";
static const char *expected_args[9];
static unsigned char expected_bytes[9][4098];
static size_t expected_sizes[9];
static int dispatch_matched;
static double expected_started;
static const char diagnostic[] = "capability-policy: process-session-unavailable\n";
static void event(int value) {
    if(event_count<sizeof(events)/sizeof(events[0])) events[event_count++]=value;
    else wrong_leaf++;
}
static int finish(void);
static void check(const char *name,int okay) {
    int clean=finish(); okay=okay && clean;
    cases++; if(!okay) failures++;
    printf("%s %s\n",okay ? "PASS" : "FAIL",name);
}
int ca_test_outer_clock(int clock,struct timespec *output) {
    event(1); unsigned index=clock_calls++;
    if(clock!=8 || !output || index>=reading_count) { wrong_leaf++; errno=EIO; return -1; }
    if(index==0) {
        if(clock_env) clock_env[0]="PATH=/usr/bin:/bin:/usr/sbin:/sbin";
        if(clock_args) clock_args[1]=(char *)check_token;
    }
    if(read_errors[index]) { errno=EIO; return -1; }
    *output=readings[index]; return 0;
}
ssize_t ca_test_outer_write(int fd,const void *bytes,size_t length) {
    event(3); diagnostic_calls++;
    if(fd!=2 || length!=sizeof(diagnostic)-1 || !bytes || memcmp(bytes,diagnostic,length)) wrong_leaf++;
    if(write_behavior==1) { errno=EIO; return -1; }
    if(write_behavior==2) return (ssize_t)(length-1);
    if(write_behavior==3) { errno=EINTR; return -1; }
    return (ssize_t)length;
}
int ca_test_outer_dispatch(const CAExecutionPins *pins,size_t count,
                          const char *const args[],CABudget *budget) {
    event(2); dispatch_calls++;
    int okay=pins && budget && count==expected_count && args &&
        !strcmp(pins->root,CA_TEST_ROOT) && !strcmp(pins->manifest_sha256,CA_TEST_SHA) &&
        !strcmp(pins->profile_id,CA_TEST_PROFILE) && !strcmp(pins->interpreter_path,CA_TEST_INTERPRETER) &&
        !strcmp(pins->interpreter_sha256,CA_TEST_SHA) && !strcmp(pins->shim_path,CA_TEST_SHIM) &&
        !strcmp(pins->shim_sha256,CA_TEST_SHA) && budget->started==expected_started &&
        budget->deadline==expected_started+58 && budget->last>=expected_started &&
        budget->last<budget->deadline && budget->read;
    if(okay) for(size_t i=0;i<count;i++) {
        if(args[i]!=expected_args[i] || (expected_sizes[i] &&
            memcmp(args[i],expected_bytes[i],expected_sizes[i])!=0)) { okay=0; break; }
    }
    if(check_continuing_clock && okay) {
        unsigned previous=clock_calls;
        okay=ca_budget_check(budget)==CA_OK && clock_calls==previous+1 &&
            budget->started==expected_started && budget->deadline==expected_started+58;
    }
    dispatch_matched=okay;
    if(real_dispatch) return ca_authority_dispatch(pins,count,args,budget);
    return dispatch_return;
}
static void reset(void) {
    memset(events,0,sizeof(events)); event_count=0;
    clock_calls=dispatch_calls=diagnostic_calls=wrong_leaf=0;
    memset(read_errors,0,sizeof(read_errors));
    reading_count=16;
    for(size_t i=0;i<reading_count;i++) readings[i]=(struct timespec){100,250000000};
    real_dispatch=dispatch_return=write_behavior=check_continuing_clock=0;
    clock_env=clock_args=NULL; expected_count=0;
    memset(expected_args,0,sizeof(expected_args)); memset(expected_sizes,0,sizeof(expected_sizes));
    dispatch_matched=0; expected_started=100.25;
    ca_handoff_test_reset(); ca_files_test_reset();
}
static int finish(void) {
    int handoff=ca_handoff_test_finish(), files=ca_files_test_finish();
    return handoff && files;
}
static void conversion_case(const char *name,struct timespec value,int accepted,double expected) {
    reset(); double output=-7;
    int result=ca_outer_test_timespec(&value,&output);
    check(name,(result==CA_OK)==accepted && (!accepted || output==expected) &&
        event_count==0 && wrong_leaf==0);
}
static void conversion_cases(void) {
    conversion_case("timespec-zero",(struct timespec){0,0},1,0);
    conversion_case("timespec-quarter",(struct timespec){100,250000000},1,100.25);
    conversion_case("timespec-fused-rounding",(struct timespec){0,959191865},1,
        0x1.eb1b3235874b7p-1);
    conversion_case("timespec-negative-seconds",(struct timespec){-1,0},0,0);
    conversion_case("timespec-negative-nanoseconds",(struct timespec){0,-1},0,0);
    conversion_case("timespec-billion-nanoseconds",(struct timespec){0,1000000000},0,0);
    conversion_case("timespec-last-nanosecond",(struct timespec){0,999999999},1,0.999999999);
    conversion_case("timespec-large-finite",(struct timespec){INT64_MAX,0},1,(double)INT64_MAX);
    reset(); double output=0;
    check("timespec-null-input",ca_outer_test_timespec(NULL,&output)==CA_REFUSED && event_count==0);
    reset(); struct timespec value={1,0};
    check("timespec-null-output",ca_outer_test_timespec(&value,NULL)==CA_REFUSED && event_count==0);
}
static void budget_case(const char *name,double initial,int accepted) {
    reset(); CABudget value; memset(&value,0,sizeof(value));
    int result=ca_outer_test_budget(initial,&value);
    int okay=(result==CA_OK)==accepted && event_count==0;
    if(accepted) {
        okay=okay && value.started==initial && value.last==initial && value.deadline==initial+58 && value.read;
        for(size_t i=0;i<reading_count;i++) readings[i]=(struct timespec){(time_t)initial,0};
        okay=okay && ca_budget_check(&value)==CA_OK && clock_calls==1 && events[0]==1;
    }
    check(name,okay && wrong_leaf==0);
}
static void budget_cases(void) {
    budget_case("budget-zero",0,1);
    budget_case("budget-valid",100,1);
    budget_case("budget-negative",-1,0);
    budget_case("budget-nan",NAN,0);
    budget_case("budget-infinity",INFINITY,0);
    budget_case("budget-negative-infinity",-INFINITY,0);
    budget_case("budget-rounded-nonincreasing",(double)INT64_MAX,0);
    budget_case("budget-max-finite-nonincreasing",DBL_MAX,0);
    reset(); check("budget-null-output",ca_outer_test_budget(0,NULL)==CA_REFUSED && event_count==0);
}
enum {
 O_CHECK,O_COMPARE,O_ENV_ORDER,O_CLOCK_ENV_ORDER,O_CLOCK_ARGS_ORDER,O_CONTINUE,
 O_DISPATCH_OK_RETURN,O_WRITE_ERROR,O_WRITE_SHORT,O_WRITE_EINTR,
 O_INITIAL_ERROR,O_INITIAL_NEGATIVE,O_INITIAL_NSEC,O_INITIAL_NONINCREASE,
 O_LATER_ERROR,O_LATER_BACKWARD,O_LATER_EQUAL,O_LATER_OVER,
 O_ENV_MISSING_PATH,O_ENV_MISSING_LOCALE,O_ENV_DUPLICATE,O_ENV_EXTRA,
 O_ENV_WRONG_PATH,O_ENV_WRONG_LOCALE,O_ENV_MALFORMED,O_ENV_OVERLONG,O_ENV_NULL,
 O_ARGC_ZERO,O_ARGV_NULL,
 O_REAL_COUNT,O_REAL_ORDER,O_REAL_RESERVED,O_REAL_LONG,O_REAL_NULL_TOKEN,O_REAL_OPERATION,
 O_TOTAL
};
static const char *const names[]={
 "check-forwarded","compare-forwarded","environment-order-permutation","clock-before-environment",
 "clock-before-arguments","retained-clock-reader","returned-dispatch-ok-still-refuses",
 "diagnostic-return-error","diagnostic-short-write","diagnostic-eintr-no-retry",
 "initial-clock-error","initial-negative-seconds","initial-invalid-nanoseconds","initial-nonincreasing-deadline",
 "later-clock-error","later-clock-backward","later-clock-deadline-equal","later-clock-deadline-exceeded",
 "environment-missing-path","environment-missing-locale","environment-duplicate","environment-extra",
 "environment-wrong-path","environment-wrong-locale","environment-malformed","environment-bounded-overlong","environment-null",
 "argc-zero-after-first-clock","argv-null-after-first-clock",
 "real-validator-invalid-count","real-validator-invalid-order","real-validator-exact-reserved-token",
 "real-validator-token-over-limit","real-validator-null-token","real-validator-invalid-operation"
};
static char oversized[4098];
static void outer_case(int scenario) {
    reset();
    char *args[11]={"synthetic-native","check","--repository-root","/synthetic/candidate",
        "--expected-sha","synthetic-sha",NULL};
    char *environment[4]={"PATH=/usr/bin:/bin:/usr/sbin:/sbin","LC_ALL=C",NULL,NULL};
    char long_environment[64]; memset(long_environment,'x',sizeof(long_environment)); long_environment[63]=0;
    int argc=6, expect_dispatch=1; char **argsp=args, **envp=environment;
    switch(scenario) {
      case O_COMPARE:
        argc=10; args[1]="compare";args[2]="--base-repository-root";args[3]="/synthetic/base";
        args[4]="--expected-base-sha";args[5]="base-sha";args[6]="--head-repository-root";
        args[7]="/synthetic/head";args[8]="--expected-head-sha";args[9]="head-sha";break;
      case O_ENV_ORDER: environment[0]="LC_ALL=C";environment[1]="PATH=/usr/bin:/bin:/usr/sbin:/sbin";break;
      case O_CLOCK_ENV_ORDER: environment[0]="WRONG=1";clock_env=environment;break;
      case O_CLOCK_ARGS_ORDER: args[1]="wrong";clock_args=args;break;
      case O_CONTINUE:
        check_continuing_clock=1;
        for(size_t i=1;i<reading_count;i++) readings[i].tv_nsec+= (long)i*1000000;
        break;
      case O_DISPATCH_OK_RETURN: dispatch_return=CA_OK;break;
      case O_WRITE_ERROR:write_behavior=1;break;
      case O_WRITE_SHORT:write_behavior=2;break;
      case O_WRITE_EINTR:write_behavior=3;break;
      case O_INITIAL_ERROR:read_errors[0]=1;expect_dispatch=0;break;
      case O_INITIAL_NEGATIVE:readings[0].tv_sec=-1;expect_dispatch=0;break;
      case O_INITIAL_NSEC:readings[0].tv_nsec=1000000000;expect_dispatch=0;break;
      case O_INITIAL_NONINCREASE:readings[0].tv_sec=INT64_MAX;expect_dispatch=0;break;
      case O_LATER_ERROR:read_errors[1]=1;expect_dispatch=0;break;
      case O_LATER_BACKWARD:readings[1].tv_sec=99;expect_dispatch=0;break;
      case O_LATER_EQUAL:readings[1].tv_sec=158;expect_dispatch=0;break;
      case O_LATER_OVER:readings[1].tv_sec=159;expect_dispatch=0;break;
      case O_ENV_MISSING_PATH:environment[0]="LC_ALL=C";environment[1]=NULL;expect_dispatch=0;break;
      case O_ENV_MISSING_LOCALE:environment[1]=NULL;expect_dispatch=0;break;
      case O_ENV_DUPLICATE:environment[1]=environment[0];expect_dispatch=0;break;
      case O_ENV_EXTRA:environment[2]="EXTRA=1";expect_dispatch=0;break;
      case O_ENV_WRONG_PATH:environment[0]="PATH=/synthetic/bin";expect_dispatch=0;break;
      case O_ENV_WRONG_LOCALE:environment[1]="LC_ALL=en_US";expect_dispatch=0;break;
      case O_ENV_MALFORMED:environment[1]="LC_ALL";expect_dispatch=0;break;
      case O_ENV_OVERLONG:environment[0]=long_environment;expect_dispatch=0;break;
      case O_ENV_NULL:envp=NULL;expect_dispatch=0;break;
      case O_ARGC_ZERO:argc=0;expect_dispatch=0;break;
      case O_ARGV_NULL:argsp=NULL;expect_dispatch=0;break;
      case O_REAL_COUNT:argc=5;real_dispatch=1;break;
      case O_REAL_ORDER:args[2]="--expected-sha";real_dispatch=1;break;
      case O_REAL_RESERVED:args[3]="--capability-bootstrap-fd";real_dispatch=1;break;
      case O_REAL_LONG:memset(oversized,'a',4097);oversized[4097]=0;args[3]=oversized;real_dispatch=1;break;
      case O_REAL_NULL_TOKEN:args[3]=NULL;real_dispatch=1;break;
      case O_REAL_OPERATION:args[1]="snapshot";real_dispatch=1;break;
      default:break;
    }
    expected_count=argc>0 ? (size_t)(argc-1) : 0;
    if(expected_count>9) { fixture_errors++; (void)finish(); return; }
    for(size_t i=0;i<expected_count;i++) {
        expected_args[i]=(scenario==O_CLOCK_ARGS_ORDER && i==0) ? check_token : args[i+1];
        if(expected_args[i]) {
            size_t length=strnlen(expected_args[i],sizeof(expected_bytes[i]));
            if(length==sizeof(expected_bytes[i])) { fixture_errors++; (void)finish(); return; }
            expected_sizes[i]=length+1;
            memcpy(expected_bytes[i],expected_args[i],length+1);
        }
    }
    int result=ca_outer_test_run(argc,argsp,envp);
    int okay=result==2 && event_count>=2 && events[0]==1 && events[event_count-1]==3 &&
        diagnostic_calls==1 && dispatch_calls==(unsigned)expect_dispatch && wrong_leaf==0;
    if(expect_dispatch) okay=okay && dispatch_matched;
    if(scenario>=O_INITIAL_ERROR && scenario<=O_INITIAL_NONINCREASE) okay=okay && clock_calls==1;
    if(scenario>=O_LATER_ERROR && scenario<=O_LATER_OVER) okay=okay && clock_calls==2;
    okay=okay && ca_handoff_test.pipe_calls==0 && ca_handoff_test.exec_calls==0 && ca_file_test.open_attempts==0;
    check(names[scenario],okay);
}
int main(void) {
    if(sizeof(names)/sizeof(names[0])!=O_TOTAL) { fixture_errors++; return 2; }
    conversion_cases(); budget_cases();
    for(int i=0;i<O_TOTAL;i++) outer_case(i);
    printf("summary cases=%u failures=%u fixture_errors=%u\n",cases,failures,fixture_errors);
    return fixture_errors ? 2 : failures ? 1 : 0;
}
