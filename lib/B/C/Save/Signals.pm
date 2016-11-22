package B::C::Save::Signals;

use strict;
use B qw(svref_2object cstring);
use B::C::Helpers qw/strlen_flags/;
use B::C::File qw( init );
use B::C::Config;    # import everything

sub is_enabled {
    return $B::C::settings->{'signals'};
}

sub set {
    return $B::C::settings->{'signals'} = shift;
}

sub enable {
    return set(1);
}

# save %SIG ( in case it was set in a BEGIN block )
sub save {
    debug( signals => "Saving signals ? %d", is_enabled() );

    return unless is_enabled();

    init()->no_split;
    my @save_sig;
    foreach my $k ( sort keys %SIG ) {
        next unless ref $SIG{$k};
        my $cvref = svref_2object( \$SIG{$k} );

        # QUESTION: where does it come from in B::C / why do we want to skip it
        #   should we skip more ?
        next if ref($cvref) eq 'B::CV' and $cvref->FILE =~ m|B/C\.pm$|;    # ignore B::C SIG warn handler
        push @save_sig, [ $k, $cvref ];
    }
    unless (@save_sig) {
        verbose( init()->add("/* no %SIG in BEGIN block */") );
        verbose(q{no %SIG in BEGIN block});
        return;
    }
    verbose( init()->add(q{/* save %SIG */}) );
    verbose(q{save %SIG});
    init()->add( "{", "\tHV* hv = get_hv(\"main::SIG\",GV_ADD);" );
    foreach my $x (@save_sig) {
        my ( $k, $cvref ) = @$x;
        my $sv = $cvref->save;
        my ( $cstring, $cur, $utf8 ) = strlen_flags($k);
        init()->sadd( qq[{\n] . "\t" . 'SV* sv = (SV*)%s;', $sv );
        init()->sadd( "\thv_store(hv, %s, %u, %s, %s);", $cstring, $cur, 'sv', 0 );

        # XXX randomized hash keys!
        init()->add( "\t" . 'mg_set(sv);', '}' );
    }
    init()->add('}');
    init()->split;

    return;
}

1;
