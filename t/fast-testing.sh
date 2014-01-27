#!/bin/bash
test -f Makefile || perl Makefile.PL
V=`perl -ane'print $F[2] if /^VERSION =/' Makefile`
R=`git log -1 --pretty=format:"%h"`
lock=fast-testing.lock
echo $$ > $lock
trap "rm $lock; exit 255" SIGINT SIGTERM

# need to kill rogue processes since we cannot use run_cmd. it disturbs stdout/err order #
# bash-4 only
coproc (while true; do
    sleep 1;
    code=`ps axw|egrep ' \./(ccode|cccode|a |aa |a.out|perldoc)'|grep -v grep`
    pid=`echo $code|perl -ane'print $F[0]'`
    test -n "$pid" && (echo $code; sleep 1s; kill $pid 2>/dev/null);
    sleep 5; done)
w=${COPROC_PID}

# test locally, ~5:45hr (17*20min)
PERLCC_TIMEOUT=15 NO_AUTHOR=1 perlall -m make '-S prove -b -j4'

kill -9 $w

# creates log.modules files with date added
# perlall -m make '-Iblib/arch -Iblib/lib t/modules.t -no-subset -no-date t/top100'

logs=`find . -maxdepth 1 -newer $lock -name log.make-\*`
if [ -n "$logs" ]; then
    rdir=t/reports/$V/$R
    mkdir -p $rdir
    cp $logs $rdir/
    rename 's/log\.make-/log\.test-/' $rdir/log.make-*
    ./status_upd -ad $rdir >> status.$V-$R
    git diff >> status.$V-$R
    cp status.$V-$R $rdir/
fi
rm $lock

