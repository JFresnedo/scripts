use List::Util qw/sum min max/;
use POSIX qw/ceil/;
use Term::ExtendedColor qw/:all/;
use Memoize;

use strict;
use warnings;

use constant MASKLEN      => 4;
use constant ERRORBLOCK   => 2000;
use constant ERRORSNPS    => 5;
use constant FS_THRESHOLD => 35;
use constant MQ_THRESHOLD => 57;

my %chisqcrit = (
    1 => 3.84,
    2 => 5.99,
    3 => 7.82,
    4 => 9.49,
    5 => 11.07,
    6 => 12.59,
    7 => 14.07,
    8 => 15.51,
);

my %maskcall = (
    A   => -1,
    H   => 1,
    B   => -1,
    '.' => 0,
);

my %swapphase = (
    "Intercross" => { "A" => "B", "B" => "A" },
    "Maternal"   => { "A" => "H", "H" => "A" },
    "Paternal"   => { "A" => "H", "H" => "A" }
);

my %callorder;

my %nullcall = ( 'GT' => './.', 'GQ' => 0 );

my @mask;

sub process {
    my ( $scf, $scfref, $samples, $data, $genetics ) = @_;
    $data->{$scf} = get_markers( $scfref, $samples, $genetics );
    find_edges( $data->{$scf}, $samples );
    collapse( $data->{$scf}, $samples );
    output_scf_to_file( $scf, $data->{$scf} );
}

sub collapse {
    my ( $scfref, $samples ) = @_;
    foreach my $type ( keys %{$scfref} ) {
        foreach my $pos ( keys %{ $scfref->{$type} } ) {
            my $gt = "";
            my @edge;
            my $cons      = "";
            my $corrected = "";
            my @gq;
            foreach my $sample ( @{ $samples->{offspring}{order} } ) {
                my $ref = $scfref->{$type}{$pos}{marker}{$sample};
                push @edge, defined $ref->{edge}
                  && $ref->{edge} != 0 ? abs( $ref->{edge} ) : '.';
                $gt        .= $ref->{gt}        // '-';
                $cons      .= $ref->{cons}      // '-';
                $corrected .= $ref->{corrected} // '-';
                push @gq, $ref->{gq};
            }
            delete $scfref->{$type}{$pos}{marker};
            $scfref->{$type}{$pos}{marker}{edge}      = \@edge;
            $scfref->{$type}{$pos}{marker}{cons}      = $cons;
            $scfref->{$type}{$pos}{marker}{corrected} = $corrected;
            $scfref->{$type}{$pos}{marker}{gt}        = $gt;
            $scfref->{$type}{$pos}{marker}{gq}        = \@gq;
        }
    }
}

sub get_markers {
    my ( $scfref, $samples, $genetics ) = @_;

    my %markers;
    my %prevpos;
    foreach my $snp ( @{$scfref} ) {
        chomp $snp;
        my ( $marker, $type, $parentcall, $pos, $info ) =
          parse_snp( $snp, $samples, $genetics );
        next if !$marker;
        next if $info->{'FS'} > FS_THRESHOLD;
        next if $info->{'MQ'} < MQ_THRESHOLD;

        check_phase( $marker, $markers{$type}{ $prevpos{$type} }{marker},
            $type )
          if ( $prevpos{$type} );
        $markers{$type}{$pos}{marker} = $marker;
        $markers{$type}{$pos}{parent} = $parentcall;
        $markers{$type}{$pos}{mq}     = $info->{'MQ'};
        $markers{$type}{$pos}{fs}     = $info->{'FS'};
        $prevpos{$type}               = $pos;
    }
    \%markers;
}

sub check_phase {
    my ( $cur, $prev, $type ) = @_;
    my $phasea = 0;
    my $phaseb = 0;
    $type =~ s/\-([AS]+)//;
    foreach my $sample ( keys %{$cur} ) {
        if ( defined $swapphase{$type}{ $cur->{$sample}{gt} } ) {
            $phasea++ if ( $cur->{$sample}{gt} eq $prev->{$sample}{gt} );
            $phaseb++
              if $swapphase{$type}{ $cur->{$sample}{gt} } eq
              $prev->{$sample}{gt};
        }
    }
    print "$type\t$phasea\t$phaseb\n";
    if ( $phaseb > $phasea ) {
        foreach my $sample ( keys %{$cur} ) {
            $cur->{$sample}{gt} = $swapphase{$type}{ $cur->{$sample}{gt} }
              // $cur->{$sample}{gt};
        }
    }
    return;
}

sub check_phase_sexspecific {
    my ( $cur, $prev ) = @_;

    return;
}

sub check_phase_intercross {
    my ( $cur, $prev ) = @_;

    my $phasea = 0;
    my $phaseb = 0;

    return;
}

sub parse_snp {
    my ( $snp, $samples, $genetics ) = @_;

    my @f     = split /\t/, $snp;
    my $callf = $f[8];
    my $pos   = $f[1];
    my @parentcalls =
      map { get_cp( 'GT', $f[ $samples->{parents}{lookup}{$_} ], $callf ) }
      @{ $genetics->{parents} };

    my ( $parentcall, $vgt ) = get_parent_call( \@parentcalls );
    return ( 0, 0, 0 )
      if ( !defined $genetics->{types}{$parentcall} );

    my %gtsbysex;
    my %marker;
    foreach my $sample ( @{ $samples->{offspring}{order} } ) {
        my $opos = $samples->{offspring}{lookup}{$sample};
        my $call = get_cp( 'GT', $f[$opos], $callf );
        my $gt   = $vgt->{$call} // "X";
        return ( 0, 0, 0 ) if $gt eq "X";

        push @{ $gtsbysex{ $genetics->{samplesex}{$sample} } }, $gt;
        $marker{$sample}{call} = $call;
        $marker{$sample}{gt}   = $gt;
        $marker{$sample}{gq}   = get_cp( 'GQ', $f[$opos], $callf );
    }

#     print "$f[0]\t$f[1]\t$parentcall\n";
#     print "Males\t@{ $gtsbysex{'Male'} }\nFemales\t@{ $gtsbysex{'Female'}}\n";
    my %types;
    for my $type ( keys %{ $genetics->{types}{$parentcall} } ) {

#        print
#"Testing $type\tExpected:\tMales:$genetics->{types}{$parentcall}{$type}{males}\tFemales:$genetics->{types}{$parentcall}{$type}{females}\n";
        $types{$type}++
          if (
            run_rms_test(
                \@{ $gtsbysex{"Male"} },
                \@{ $gtsbysex{"Female"} },
                $genetics->{types}{$parentcall}{$type}{males},
                $genetics->{types}{$parentcall}{$type}{females},
                $genetics->{rms}
            )
          );

    }
    my @t = sort keys %types;
    push @t, "Reject" if ( @t == 0 );

    #        print "$parentcall\t@t\n";
    return ( 0, 0, 0 ) if keys %types != 1;

    my $type = ( keys %types )[0];
    return ( 0, 0, 0 ) if $type eq "Reject";

    # Correct eg B/- to H
    if ( defined $genetics->{types}{$parentcall}{$type}{corrections} ) {
        foreach my $sample ( @{ $samples->{offspring}{order} } ) {
            $marker{$sample}{gt} =
              $genetics->{types}{$parentcall}{$type}{corrections}
              { $marker{$sample}{gt} } // $marker{$sample}{gt};
        }
    }

    my @info = split /;/, $f[7];
    my %info;
    map { $info{$1} = $2 if (/^(.+)=(.+)$/); } @info;

    return ( \%marker, $type, $parentcall, $pos, \%info );
}

sub run_rms_test {
    my ( $malecalls, $femalecalls, $validmale, $validfemale, $rms ) = @_;

    my %exp;
    my %male_p;
    my %female_p;
    get_expected_classes( \%exp, 'M', $malecalls,   $validmale,   \%male_p );
    get_expected_classes( \%exp, 'F', $femalecalls, $validfemale, \%female_p );

    my $n = @{$malecalls} + @{$femalecalls};
    my %obs;
    map { $obs{"M$_"}++ } @{$malecalls};
    map { $obs{"F$_"}++ } @{$femalecalls};

    my $rms_obs     = get_rms( \%obs, \%exp );
    my $rms_pattern = "$validmale:$validfemale";
    my $p           = 0.99;
    while ( $p > 0 && $rms_obs >= $rms->{$rms_pattern}{$p} ) {
        $p -= 0.01;
        $p = sprintf "%.2f", $p;
    }

    #    print "RMS=$rms_obs p = $p\n";
    return $p > 0.05;
}

sub get_rms {
    my ( $obs, $exp ) = @_;

    my $rms;
    for my $c ( 'MA', 'MB', 'MH', 'M.', 'FA', 'FB', 'FH', 'F.' ) {
        my $obsv = $obs->{$c} // 0;
        my $expv = $exp->{$c} // 0;
        $rms += ( $obsv - $expv )**2;
    }
    $rms = sqrt( $rms / 8 );

    return $rms;
}

sub get_expected_classes {
    my ( $exp_ref, $sex, $calls, $valid, $p ) = @_;
    my @exp = split /,/, $valid;
    my $shares = 0;
    for my $e (@exp) {
        if ( $e =~ /^(\d)?([ABH.])$/ ) {
            my $share = $1 // 1;
            $exp_ref->{"$sex$2"} = $share;
            $shares += $share;
        }
    }
    my $cum_prob = 0;
    for my $e (@exp) {
        $e = $2 if ( $e =~ /^(\d)([ABH.])$/ );
        my $prob = $exp_ref->{"$sex$e"} / $shares;
        $exp_ref->{"$sex$e"} = $prob * @{$calls};
        $p->{"$e"}{min} = $cum_prob;
        $cum_prob += $prob;
        $p->{"$e"}{max} = $cum_prob;
    }
}

sub get_parent_call {
    my ($parents) = @_;

    my @hom;
    my %hom;
    my %het;

    # Get unique homozygote alleles and heterozygote calls
    for my $pc ( @{$parents} ) {
        my ( $i, $j ) = $pc =~ /(.)\/(.)/;
        if ( $i eq $j ) {
            push @hom, $i if !defined $hom{$i};
            $hom{$i}++;
        }
        else {
            $het{$pc}++;
        }
    }

    return ( "XXX", 0 )
      if ( defined $hom{'.'} && keys %hom > 3
        or !defined $hom{'.'} && keys %hom > 2
        or keys %het > 1 );

    # At this point, we have up to two homozygous calls in @hom
    # and at most one heterozygous call in keys %het

    my @valleles = ( "A", "B" );

    # Assign 0,1,2 etc alleles to A and B symbols
    my %vallele;
    for my $hom (@hom) {
        next if ( $hom eq '.' );
        $vallele{$hom} = shift @valleles;
    }

    if ( @valleles && keys %het ) {
        for my $allele ( ( keys %het )[0] =~ /(.)\/(.)/ ) {
            $vallele{$allele} = shift @valleles
              if ( !defined $vallele{$allele} );
        }
    }
    return ( "XXX", 0 ) if keys %vallele > 2;

    my @vas = sort { $a <=> $b } keys %vallele;
    my %vgt;
    if ( defined $vas[0] ) {
        $vgt{"$vas[0]/$vas[0]"} = "$vallele{$vas[0]}";
        if ( defined $vas[1] ) {
            $vgt{"$vas[1]/$vas[1]"} = "$vallele{$vas[1]}";
            $vgt{"$vas[0]/$vas[1]"} = 'H';
        }
    }
    $vgt{"./."}   = '.';
    $vallele{"."} = ".";

    # Assign A, B and H (for heterozygote) to parental calls
    my $parentcall;
    for my $pc ( @{$parents} ) {
        my ( $i, $j ) = $pc =~ /(.)\/(.)/;
        $parentcall .= ( $i eq $j ) ? $vallele{$i} : 'H';
    }

    return ( $parentcall, \%vgt );
}

sub get_cp {
    my ( $part, $call, $order ) = @_;

    return $nullcall{$part} if $call eq './.';

    my @cp = split ':', $call;
    if ( !defined $callorder{$order} ) {
        my @neworder = split ':', $order;
        map { $callorder{$order}{ $neworder[$_] } = $_ } 0 .. $#neworder;
    }

    return $cp[ $callorder{$order}{$part} ];
}

sub find_edges {
    my $markers = shift;
    my $samples = shift;

    foreach my $type ( keys %{$markers} ) {
        my @pos = sort { $a <=> $b } keys %{ $markers->{$type} };
        foreach my $sample ( @{ $samples->{offspring}{order} } ) {
            get_sample_blocks( $markers->{$type}, $sample, \@pos, MASKLEN );
            get_block_consensus( $markers->{$type}, $sample, \@pos, MASKLEN );
            clean_blocks( $markers->{$type}, $sample, \@pos );
        }
    }
}

sub clean_blocks {
    my ( $marker, $sample, $pos ) = @_;

    my $blocknum = 0;
    my @blocks;
    my $prev_cons;
    for my $p ( @{$pos} ) {
        $blocknum++
          if ( defined $prev_cons
            && $prev_cons ne $marker->{$p}{marker}{$sample}{cons} );
        push @{ $blocks[$blocknum]{pos} }, $p;
        $blocks[$blocknum]{cons} = $marker->{$p}{marker}{$sample}{cons};
        $prev_cons = $marker->{$p}{marker}{$sample}{cons};
    }

    for my $b ( 0 .. $#blocks ) {
        if (
               @blocks >= 3
            && $b >= 1
            && $b <= $#blocks - 1
            && $blocks[ $b - 1 ]{cons} eq $blocks[ $b + 1 ]{cons}
            && $blocks[ $b - 1 ]{cons} ne $blocks[$b]{cons}
            && ( ( max( @{ $blocks[$b]{pos} } ) - min( @{ $blocks[$b]{pos} } ) )
                < ERRORBLOCK )
            || ( @{ $blocks[$b]{pos} } <= ERRORSNPS )
          )
        {
            for my $p ( @{ $blocks[$b]{pos} } ) {
                $marker->{$p}{marker}{$sample}{corrected} =
                  $blocks[ $b - 1 ]{cons};
            }
            $blocks[$b]{cons} = $blocks[ $b - 1 ]{cons};
        }
        else {
            for my $p ( @{ $blocks[$b]{pos} } ) {
                $marker->{$p}{marker}{$sample}{corrected} =
                  $marker->{$p}{marker}{$sample}{cons};
            }
        }
    }
}

sub get_sample_blocks {
    my ( $marker, $sample, $pos, $masklen, $mask ) = @_;

    @mask = ( (-1) x $masklen, 0, (1) x $masklen ) if ( !@mask );
    my @called;
    foreach my $p ( @{$pos} ) {
        push @called, $p
          if $maskcall{ $marker->{$p}{marker}{$sample}{gt} } != 0;
    }

    foreach my $i ( $masklen .. $#called - $masklen ) {
        next if defined $marker->{ $called[$i] }{marker}{$sample}{edge};
        my @maskcallpos = @called[ $i - $masklen .. $i + $masklen ];

        my $edgesum = 0;

        $marker->{ $called[$i] }{marker}{$sample}{edge} = int sum map {
            $maskcall{ $marker->{ $maskcallpos[$_] }{marker}{$sample}{gt} } *
              $mask[$_]
        } 0 .. $#mask;
    }
}

sub get_block_consensus {
    my ( $marker, $sample, $pos, $masklen ) = @_;
    my @blockpos;
    my @blocks;
    foreach my $p ( @{$pos} ) {
        if ( defined $marker->{$p}{marker}{$sample}{edge}
            && abs( $marker->{$p}{marker}{$sample}{edge} ) > $masklen )
        {
            # Don't include the edge position in the block to date;
            # calculate the consensus for the edge block on its own,
            # then move on to the following positions
            calculate_consensus( \@blockpos, $marker, $sample )
              if @blockpos >= 1;
            @blockpos = ($p);
            calculate_consensus( \@blockpos, $marker, $sample );
            @blockpos = ();
        }
        else {
            push @blockpos, $p;
        }

    }
    calculate_consensus( \@blockpos, $marker, $sample );
}

sub calculate_consensus {
    my ( $blockpos, $marker, $sample ) = @_;
    my %blockgt;

    map {
        $blockgt{ $marker->{$_}{marker}{$sample}{gt} }++;

        #        $blockgt{ $marker->{$_}{marker}{$sample}{gt} } +=
        #          $marker->{$_}{marker}{$sample}{gq}
    } @{$blockpos};

    my $maxgt = ( sort { $blockgt{$b} <=> $blockgt{$a} } keys %blockgt )[0];
    map { $marker->{$_}{marker}{$sample}{cons} = $maxgt } @{$blockpos};
}

sub merge {
    my ( $part, $all ) = @_;
    foreach my $scf ( keys %{$part} ) {
        $all->{scf}{$scf}++;
    }
}

sub output {
    my ( $data, $samples, $genome, $outfix ) = @_;
    print STDERR "Outputting...\n";

    open my $allout, '>', "$outfix.out"
      or croak "Can't open $outfix.out: $OS_ERROR\n";
    foreach my $scf ( sort keys %{ $data->{scf} } ) {
        open my $scffile, '<', "$scf.tmp.out"
          or croak "Can't open scf output for $scf: $OS_ERROR\n";
        while ( my $scfline = <$scffile> ) {
            print $allout $scfline;
        }
        close $scffile;
        system("rm $scf.tmp.out");
    }
    close $allout;
}

sub output_scf_to_file {
    my ( $scf, $data ) = @_;
    open my $scfhandle, '>', "$scf.tmp.out"
      or croak "Can't open output file for $scf: $OS_ERROR\n";
    output_scf( $scf, $data, $scfhandle );
    close $scfhandle;
}

sub output_scf {
    my ( $scf, $data, $handle ) = @_;
    foreach my $type ( sort keys %{$data} ) {
        foreach my $pos ( sort { $a <=> $b } keys %{ $data->{$type} } ) {

            print $handle
"$scf\t$pos\t$type\t$data->{$type}{$pos}{parent}\t$data->{$type}{$pos}{mq}\t$data->{$type}{$pos}{fs}\t";
            my @gt = split //, $data->{$type}{$pos}{marker}{gt};
            foreach my $i ( 0 .. $#gt ) {
                my $col =
                  ceil( 255 - $data->{$type}{$pos}{marker}{gq}[$i] / 4.2 );
                print $handle fg $col, $gt[$i];
            }
            print $handle "\t";

            my @edge      = @{ $data->{$type}{$pos}{marker}{edge} };
            my @cons      = split //, $data->{$type}{$pos}{marker}{cons};
            my @corrected = split //, $data->{$type}{$pos}{marker}{corrected};

            if ( @cons == 0 or @corrected == 0 ) {
                print $handle "\n";
                next;
            }
            my $cons      = "";
            my $corrected = "";
            foreach my $e ( 0 .. $#edge ) {
                my $col =
                  $edge[$e] ne '.' && $edge[$e] > MASKLEN ? 'red1' : 'black';
                print $handle fg $col, $edge[$e];
                $cons      .= fg $col, $cons[$e];
                $corrected .= fg $col, $corrected[$e];
            }
            print $handle "\t$cons\t$corrected\n";
        }
        print $handle '-' x 253, "\n";
    }
    print $handle '-' x 253, "\n";

}

1;
