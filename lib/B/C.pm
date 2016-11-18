#      C.pm
#
#      Copyright (c) 1996, 1997, 1998 Malcolm Beattie
#      Copyright (c) 2008, 2009, 2010, 2011 Reini Urban
#      Copyright (c) 2010 Nick Koston
#      Copyright (c) 2011-2017 cPanel Inc
#
#      You may distribute under the terms of either the GNU General Public
#      License or the Artistic License, as specified in the README file.
#

package B::C;

our $VERSION = '5.024010';
our $caller  = caller;       # So we know how we were invoked.

our @ISA = qw(Exporter);

our @EXPORT_OK = qw(set_callback save_context svop_or_padop_pv inc_cleanup opsect_common fixup_ppaddr);

# can be improved
our $nullop_count     = 0;
our $unresolved_count = 0;

our $gv_index = 0;

our $const_strings = 1;      # TODO: This var needs to go away.

our $settings = {
    'signals'       => 1,
    'debug_options' => '',
    'output_file'   => '',
    'init_name'     => '',
    'skip_packages' => {},
    'used_packages' => {},
};

# This loads B/C_heavy.pl from the same location C.pm came from.
sub load_heavy {
    my $bc = $INC{'B/C.pm'};
    $bc =~ s/\.pm$/_heavy.pl/;
    require $bc;
}

# This is the sub called once the BEGIN state completes.
# We want to capture stash and %INC information before we go and corrupt it!
sub build_c_file {
    my (@opts) = @_;
    parse_options(@opts);    # Parses command line options and populates $settings where necessary
    load_heavy();            # Loads B::C_heavy.pl
    start_heavy();           # Invokes into B::C_heavy.pl
}

# This is what is called when you do perl -MO=C,....
# It tells O.pm what to invoke once the program completes the BEGIN state.
sub compile {
    my (@argv) = @_;
    $DB::single = 1 if defined &DB::DB;
    return sub { build_c_file(@argv) };
}

# This parses the options passed to sub compile but not until build_c_file is invoked at the end of BEGIN.
# It is NOT SAFE to mess with anything outside of the %B::C:: stash

sub parse_options {
    my (@opts) = @_;
    my ( $option, $opt, $arg );

    while ( $option = shift @opts ) {
        next unless length $option;    # fixes -O=C,,-v,...
        if ( $option =~ /^-(.)(.*)/ ) {
            $opt = $1;
            $arg = $2 || '';
        }
        else {
            die( "Unexpected options passed to O=C: " . join( ",", @opts ) );
        }

        if ( $opt eq "-" && $arg eq "-" ) {
            die( "Unexpected options passed to O=C: --" . join( ",", @opts ) );
        }

        if ( $opt eq "w" ) {
            $settings->{'warn_undefined_syms'} = 1;
        }
        elsif ( $opt eq "D" ) {
            $arg ||= shift @opts;
            $arg =~ s{^=+}{};
            $settings->{'debug_options'} .= $arg;
        }
        elsif ( $opt eq "o" ) {
            $arg ||= shift @opts;
            $settings->{'output_file'} = $arg;
        }
        elsif ( $opt eq "s" and $arg eq "taticxs" ) {
            $settings->{'staticxs'} = 1;
        }
        elsif ( $opt eq "n" ) {
            $arg ||= shift @opts;
            $settings->{'init_name'} = $arg;
        }
        elsif ( $opt eq "m" ) {
            $settings->{'used_packages'}->{$arg} = 1;
        }
        elsif ( $opt eq "v" ) {
            $settings->{'enable_verbose'} = 1;
        }
        elsif ( $opt eq "u" ) {
            $arg ||= shift @opts;
            if ( $arg =~ /\.p[lm]$/ ) {
                eval "require(\"$arg\");";    # path as string
            }
            else {
                eval "require $arg;";         # package as bareword with ::
            }
            $settings->{'used_packages'}->{$arg} = 1;
        }
        elsif ( $opt eq "U" ) {
            $arg ||= shift @opts;
            $settings->{'skip_packages'}->{$arg} = 1;
        }
        else {
            die "Invalid option $opt";
        }
    }

    @opts and die("Used to call B::C::File::output_all but this sub has been gone for a while!");

    return;
}

1;

__END__

=head1 NAME

B::C - Perl compiler's C backend

=head1 SYNOPSIS

	perl -MO=C[,OPTIONS] foo.pl

=head1 DESCRIPTION

This compiler backend takes Perl source and generates C source code
corresponding to the internal structures that perl uses to run
your program. When the generated C source is compiled and run, it
cuts out the time which perl would have taken to load and parse
your program into its internal semi-compiled form. That means that
compiling with this backend will not help improve the runtime
execution speed of your program but may improve the start-up time.
Depending on the environment in which your program runs this may be
either a help or a hindrance.

=head1 OPTIONS

If there are any non-option arguments, they are taken to be
names of objects to be saved (probably doesn't work properly yet).
Without extra arguments, it saves the main program.

=over 4

=item B<-o>I<filename>

Output to filename instead of STDOUT

=item B<-n>I<init_name>

Default: "perl_init" and "init_module"

=item B<-v>

Verbose compilation. Currently gives a few compilation statistics.

=item B<-u>I<Package> "use Package"

Force all subs from Package to be compiled.

This allows programs to use eval "foo()" even when sub foo is never
seen to be used at compile time. The down side is that any subs which
really are never used also have code generated. This option is
necessary, for example, if you have a signal handler foo which you
initialise with C<$SIG{BAR} = "foo">.  A better fix, though, is just
to change it to C<$SIG{BAR} = \&foo>. You can have multiple B<-u>
options. The compiler tries to figure out which packages may possibly
have subs in which need compiling but the current version doesn't do
it very well. In particular, it is confused by nested packages (i.e.
of the form C<A::B>) where package C<A> does not contain any subs.

=item B<-U>I<Package> "unuse" skip Package

Ignore all subs from Package to be compiled.

Certain packages might not be needed at run-time, even if the pessimistic
walker detects it.

=item B<-staticxs>

Dump a list of bootstrapped XS package names to F<outfile.lst>
needed for C<perlcc --staticxs>.
Add code to DynaLoader to add the .so/.dll path to PATH.

=item B<-D>C<[OPTIONS]>

Debug options, concatenated or separate flags like C<perl -D>.
Verbose debugging options are crucial, because the interactive
debugger L<Od> adds a lot of ballast to the resulting code.

=item B<-Dfull>

Enable all full debugging, as with C<-DoOcAHCMGSpWF>.
All but C<-Du>.

=item B<-Do>

All Walkop'ed OPs

=item B<-DO>

OP Type,Flags,Private

=item B<-DS>

Scalar SVs, prints B<SV/RE/RV> information on saving.

=item B<-DP>

Extra PV information on saving. (static, len, hek, fake_off, ...)

=item B<-Dc>

B<COPs>, prints COPs as processed (incl. file & line num)

=item B<-DA>

prints B<AV> information on saving.

=item B<-DH>

prints B<HV> information on saving.

=item B<-DC>

prints B<CV> information on saving.

=item B<-DG>

prints B<GV> information on saving.

=item B<-DM>

prints B<MAGIC> information on saving.

=item B<-DR>

prints B<REGEXP> information on saving.

=item B<-Dp>

prints cached B<package> information, if used or not.

=item B<-Ds>

prints all compiled sub names, optionally with " not found".

=item B<-DF>

Add Flags info to the code.

=item B<-DW>

Together with B<-Dp> also prints every B<walked> package symbol.

=item B<-Du>

do not print B<-D> information when parsing for the unused subs.

=item B<-Dr>

Writes debugging output to STDERR and to the program's generated C file.
Otherwise writes debugging info to STDERR only.

=back

=head1 EXAMPLES

    perl -MO=C,-ofoo.c foo.pl
    perl cc_harness -o foo foo.c

Note that C<cc_harness> lives in the C<B> subdirectory of your perl
library directory. The utility called C<perlcc> may also be used to
help make use of this compiler.

    perlcc foo.pl

    perl -MO=C,-v,-DcA bar.pl > /dev/null

=over

=item Warning: Problem with require "$name" - $INC{file.pm}

Dynamic load of $name did not add the expected %INC key.

=item Warning: C.xs PMOP missing for QR

In an initial C.xs runloop all QR regex ops are stored, so that they
can matched later to PMOPs.

=item Warning: DynaLoader broken with 5.15.2-5.15.3.

[perl #100138] DynaLoader symbols were XS_INTERNAL. Strict linking
could not resolve it. Usually libperl was patched to overcome this
for these two versions.
Setting the environment variable NO_DL_WARN=1 omits this warning.

=item Warning: __DATA__ handle $fullname not stored. Need -O2 or -fsave-data.

Since processing the __DATA__ filehandle involves some overhead, requiring
PerlIO::scalar with all its dependencies, you must use -O2 or -fsave-data.

=item Warning: Write BEGIN-block $fullname to FileHandle $iotype \&$fd

Critical problem. This must be fixed in the source.

=item Warning: Read BEGIN-block $fullname from FileHandle $iotype \&$fd

Critical problem. This must be fixed in the source.

=item Warning: -o argument ignored with -c

-c does only check, but not accumulate C output lines.

=item Warning: unresolved $section symbol s\\xxx

This symbol was not resolved during compilation, and replaced by 0.

With B::C this is most likely a critical internal compiler bug, esp. if in
an op section. See [issue #110].

With B::CC it can be caused by valid optimizations, e.g. when op->next
pointers were inlined or inlined GV or CONST ops were optimized away.

=back

=head1 BUGS

Current status: A few known bugs, but usable in production

=head1 AUTHOR

Malcolm Beattie C<MICB at cpan.org> I<(1996-1998, retired)>,
Nick Ing-Simmons <nik at tiuk.ti.com> I(1998-1999),
Vishal Bhatia <vishal at deja.com> I(1999),
Gurusamy Sarathy <gsar at cpan.org> I(1998-2001),
Mattia Barbon <mbarbon at dsi.unive.it> I(2002),
Reini Urban C<perl-compiler@googlegroups.com> I(2008-)

=head1 SEE ALSO

L<perlcompiler> for a general overview,
L<B::CC> for the optimising C compiler,
L<B::Bytecode> + L<ByteLoader> for the bytecode compiler,
L<Od> for source level debugging in the L<B::Debugger>,
L<illguts> for the illustrated Perl guts,
L<perloptree> for the Perl optree.

=cut

# Local Variables:
#   mode: cperl
#   cperl-indent-level: 2
#   fill-column: 78
# End:
# vim: expandtab shiftwidth=2:
