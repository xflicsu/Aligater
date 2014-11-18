#!/usr/bin/env perl
#
##
##  Author: Tim Sterne-Weiler, timbitz (Oct 2014)
##  e-mail: tim.sterne.weiler@utoronto.ca
##

# This program accepts SAM format as stdin, and looks for chimeric reads.
# It is designed to be called by `aligater` which pipes to samtools for BAM
# format if necessary, though this is not required with SAM input.

use warnings;
use strict;

use Cwd qw(abs_path);
use POSIX qw(strftime);
use Digest::MD5 qw(md5_hex md5_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long;

use GeneAnnot; # oop
use SamBasics qw(:all);
use FuncBasics qw(isInt shove openFileHandle);
use CoordBasics qw(coorOverlap parseRegion);
use SequenceBasics qw(maskstr revComp);

our $COORDEXPAND = 1000; # this is the buffer range for overlapping genomic loci

our $STRAND_SPECIFIC = 1; # transcriptome mapping.-->SETTING TO 0 IS NOT RECOMMENDED!
our $HYBRID_PENALTY = -24; # this should be optimized.
our $ANTISENSE_PENALTY = -24; #so should this

our %GENEFAM;  # load this from anno/Species.gene_families.txt;
our $GENEANNO;  # GeneAnnot object if --gtf=s is used to specify genome coordinates

# INITIALIZE
my $path = abs_path($0);
$0 =~ s/^.*\///;
$path =~ s/\/$0$//;

# set default output prefix based on timestamp
my $outputCore = strftime 'Output_%F_%H.%M.%S', localtime;

my $base64Flag = 0;
my $suppressAlnFlag = 0;

my $gtfFile; #undef by default
my $geneFamFile;

GetOptions("o=s" => \$outputCore, 
           "base" => \$base64Flag,
           "noaln" => \$suppressAlnFlag,
           "noanti" => \$STRAND_SPECIFIC, #TODO
           "gfam=s" => \$geneFamFile,
           "gtf=s" => \$gtfFile);

my $nonHybHndl;
my $hybHndl; # alignment output filehandles.

unless($suppressAlnFlag) {
  open($nonHybHndl, "| samtools view -bS - > $outputCore.std.bam") or die "Can't write to $outputCore.bam";
  open($hybHndl,"| samtools view -bS - > $outputCore.lig.bam") or die "Can't write to $outputCore.chimera.bam";
}
# don't die, explode!
sub explode {
  my $str = shift;
  chomp($str);
  die "[aligater detect]: (Input Line $.) ERROR $str\n";
}

sub reverb {
  my $str = shift;
  chomp($str);
  print STDERR "[$0]: ($.) $str\n";
}

## Load GTF/GFF file if defined;
if(defined($gtfFile)) {
  $GENEANNO = new GeneAnnot;
  $GENEANNO->load_GFF_or_GTF($gtfFile, 1);
}
# done loading GTF

# load gene family file if possible
if(defined($geneFamFile)) {
  my $geneHndl = openFileHandle($geneFamFile);
  while(my $l = <$geneHndl>) {
    next if $l =~ /^#/;
    chomp $l;
    my(@a) = split(/\t/, $l);
    explode "Improper gene family file format!" unless defined($a[0]) and defined($a[1]);
    $GENEFAM{$a[1]} = $a[0];
  }
  close $geneHndl;
}
# done loading gene family file

# set iteraters
# this stores the current set of alignments
my $alnHash = {}; #reference to hash
my $sHash = {}; #alignment starts (in read)
my $eHash = {}; #alignment ends (in read)
my $seHash = {}; #alignment "start:end"

my $curRead = "";
my $curCount = 1;

# iterate through sam alignments
while(my $l = <>) {
  if($l =~ /^(#|\@(SQ|HD|RG|PG|CO))/) { #header line
    unless($suppressAlnFlag) {
      print $hybHndl $l;
      print $nonHybHndl $l;
    }
    next;
  }
  chomp($l);
  my(@a) = split(/\t/, $l); # split sam
  next unless isMapped($a[1]); # ignore unmapped reads 
  explode "Invalid SAM format!\n" unless(defined($a[0]) and isInt($a[1]));

  # substitute current readname for cleaner md5
  $a[0] = ($base64Flag) ? md5_base64($a[0]) : md5_hex($a[0]);
  $a[0] = substr($a[0], 0, 12);  # 10 ** 18 should be enough
   
  if($a[0] ne $curRead and $curRead ne "") {
    # before moving to a new read, process current read's alignments
    # from $alnHash

    # process algorithm here...
    processAlignRec($alnHash, $sHash, $eHash);

    #output best alignment here.
    my($bestK) = sort { alignCmp($alnHash->{$b}, $alnHash->{$a}) } keys %$alnHash;
    if(defined $bestK) {
      if($bestK =~ /\:/) { # chimeric read
        my $hybrid = getHybridFormat($bestK, $alnHash);
        my(@alns) = split(/\:/, $bestK);
        foreach my $al (@alns) {
          my $aRef = $alnHash->{$al};
          my $samOutput = join("\t", @$aRef[3 .. $#$aRef]); #TODO if $gtfFile convert sam to genomic
          print $hybHndl "$samOutput\n" unless $suppressAlnFlag;
        }
      } else { #non-chimeric read
        my $aRef = $alnHash->{$bestK};
        my $samOutput = join("\t", @$aRef[3 .. $#$aRef]);
        print $nonHybHndl "$samOutput\n" unless $suppressAlnFlag; # best non-chimeric alignments
      }
    }
    # re-initialize for new read
    $curRead = $a[0];
    $curCount = 1;
    ($alnHash, $sHash, $eHash, $seHash) = ({}, {}, {}, {}); # empty hash refs..
  }

  # process current read.
  explode "Invalid CIGAR format!" unless isCIGAR($a[5]); 
  my $strand = getStrand($a[1]); 
  #discard if - strand and strand specific?
  next if($STRAND_SPECIFIC and $strand eq "-");
  my($start, $len) = alignPosInRead($a[5]);
  my $end = $start + $len;
  if($strand eq "-") { #if - strand, reverse position
    $start = length($a[9]) - $end; # TODO TEST
    $end = $start + $len;
  }
  my $optHash = parseOpFields(\@a); 
  my $aScore = $optHash->{"AS"};
  #my $numMiss = $optHash->{"NM"};   

  # if same start/end exists.. take best;
  my $curAln = shove([$aScore, $start, $len], @a);  #???

  # add start and end records.
  $sHash->{$start} = shove($sHash->{$start}, $curCount);
  $eHash->{$end} = shove($eHash->{$end}, $curCount);

  # record full alignment
  $alnHash->{$curCount} = $curAln; 

  # increment for next read;
  $curCount++;
  $curRead = $a[0];
}

unless($suppressAlnFlag) {
  close $nonHybHndl;
  close $hybHndl;
}

#######################################################
#						      #
################# BEGIN SUBROUTINES ###################
#						      #
#######################################################

# Recursively process/collapse alignments.
sub processAlignRec {
  my($alnHash, $sHash, $eHash) = @_;
  my $found = [];
  foreach my $end (sort keys %$eHash) {
    my $curList = $eHash->{$end};
    my $findList = [];
    if(defined($sHash->{$end})) {
      push(@$findList, @{$sHash->{$end}});
      push(@$found, $end);
    } 
    if(defined($sHash->{$end - 1})) {
      push(@$findList, @{$sHash->{$end - 1}});
      push(@$found, $end - 1);
    } 
    if(defined($sHash->{$end + 1})) {
      push(@$findList, @{$sHash->{$end + 1}});
      push(@$found, $end + 1);
    }
    
    # now go through and make hybrids
    foreach my $a (@$curList) {
      foreach my $b (@$findList) {
        my($score, $start, $len);
        explode "$a and $b are not defined in alnHash!" unless 
		defined($alnHash->{$a}) and defined($alnHash->{$b}); 
        my $antiPenalty = ($alnHash->{$a}->[4] ne "hybrid" and getStrand($alnHash->{$a}->[4]) eq "-") ? $ANTISENSE_PENALTY : 0;
        $antiPenalty += ($alnHash->{$b}->[4] ne "hybrid" and getStrand($alnHash->{$b}->[4]) eq "-") ? $ANTISENSE_PENALTY : 0; #TODO TEST;
        $score = $alnHash->{$a}->[0] + $alnHash->{$b}->[0] + $HYBRID_PENALTY + $antiPenalty;
        $start = $alnHash->{$a}->[1];
        $len = ($alnHash->{$b}->[1] + $alnHash->{$b}->[2]) - $alnHash->{$a}->[1];
        my $readName = $alnHash->{$a}->[3];
        # set alnHash value for new hybrid
        my $geneIdHyb = "$alnHash->{$a}->[5]\:\-\:$alnHash->{$b}->[5]";
        $alnHash->{"$a\:$b"} = [$score, $start, $len, $readName, "hybrid", $geneIdHyb];
        $eHash->{$start+$len} = shove($eHash->{$start+$len}, "$a\:$b");
      }
    }

  } # end itor

  # now clean up those starts so we don't
  # pick them up on the next recurse
  foreach my $start (@$found) {
    next unless defined($sHash->{$start});
    delete $sHash->{$start};
  }
  # end condition if no more hybrids are found.
  (scalar @$found) ? processAlignRec($alnHash, $sHash, $eHash) : return;
}

# this function outputs the `.lig` file format...
sub getHybridFormat {
  my($hyb, $alnHash) = @_;
  explode "getHybridFormat ERROR!\n" unless (defined($hyb) and defined($alnHash));
  my(@a) = split(/\:/, $hyb);
  my $alpha = join("", ("A".."Z"));
  my(%used);
  my $charStruct = $hyb;
  my $geneSymStruct = $hyb;
  my $ensTranStruct = $hyb;
  my $ensGeneStruct = $hyb;
  my $biotypeStruct = $hyb;

  my $refPositions = $hyb;
  $refPositions =~ s/:/,/g;
  my $genPositions = $hyb;
  $genPositions =~ s/:/,/g;
  my $alnLengths = $refPositions;

  my $ligSitePos = "";
  my $readName = $alnHash->{$hyb}->[3];
  my $alnScore = $alnHash->{$hyb}->[0];

  my $readSeq = $alnHash->{1}->[12];  # get raw read sequence in forward orientation
  $readSeq = revComp($readSeq) if (getStrand($alnHash->{1}->[4]) eq "-"); # TEST TODO

  # convert chimeric read structures from gene symbol-> segment character
  for(my $i=0; $i < scalar(@a); $i++) {
    my $id = $a[$i];
    my $char = substr($alpha, scalar keys %used, 1);
    my($ensTran, $ensGene, $geneSym, $biotype) = split(/\_/, $alnHash->{$id}->[5]);
    my $refPos = $alnHash->{$id}->[6]; 
    my $readPos = $alnHash->{$id}->[1];
    my $length = $alnHash->{$id}->[2];
    my $strand = getStrand($alnHash->{$id}->[4]); # TODO TEST

    # set genomic position if possible
    my $coord = $GENEANNO->toGenomeCoord($ensTran, $refPos) if defined($GENEANNO);
    my($genomeChr, $genomePos, $genomeRan) = parseRegion($coord);
    # if - strand alignment, reverse genomeRan
    $genomeRan = (defined($genomeRan) and $genomeRan eq "+") ? "-" : "+" if($strand eq "-"); # quaternary operator? ;-)
    my $genomeCoord = (defined($genomePos)) ? "$genomeChr\:$genomePos\:$genomeRan" : "NA";    

    # set previously used char for same gene symbol
    if(defined($used{$geneSym})) {
      $char = $used{$geneSym};
    }
    $char = "-$char" if $strand eq "-"; # mark the antisense structure; #TODO TEST

    # substitute hyb number for char or sym etc;
    $charStruct    =~ s/\b(?<!\-)$id(?!\-)\b/$char/g;
    $geneSymStruct =~ s/\b(?<!\-)$id(?!\-)\b/$geneSym/g;
    $ensTranStruct =~ s/\b(?<!\-)$id(?!\-)\b/$ensTran/g;
    $ensGeneStruct =~ s/\b(?<!\-)$id(?!\-)\b/$ensGene/g;
    $biotypeStruct =~ s/\b(?<!\-)$id(?!\-)\b/$biotype/g;

    # push alignment start position in reference.
    $refPositions  =~ s/\b(?<!\-)$id(?!\-)\b/$refPos/;
    $genPositions  =~ s/\b(?<!\-)$id(?!\-)\b/$genomeCoord/;
    $alnLengths    =~ s/\b(?<!\-)$id(?!\-)\b/$length/;

    # make read sequence structure;
    if($i == 0) { # first alignment
      $readSeq = maskstr($readSeq, 0, $readPos) if ($readPos > 1);
    } elsif($i == $#a) { #last alignment
      $readSeq = maskstr($readSeq, $readPos+$length - 1, length($readSeq) - ($readPos+$length) + 1);
    }
    #insert _ at ligation site. 
    substr($readSeq, $readPos - 1, 0, "_") unless($i == 0);

    $used{$geneSym} = $char;
  }
  # get hybrid code and gene family structure.
  my($hybCode, $familyStruct) = getHybridCode($charStruct, $geneSymStruct, $genPositions); 
  $charStruct =~ tr/B-Z/A/ if $hybCode eq "S"; # if we changed the hybCode, alter charStruct to match.
  print "$hybCode\t$charStruct\t$hyb\t$geneSymStruct\t$ensGeneStruct\t$ensTranStruct\t$biotypeStruct";
  print "\t$readName\t$readSeq\t$alnScore\t$refPositions\t$alnLengths\t$genPositions\n";
}

# I = putative inter-molecular, R = paralogous intra-molecular, S = intra-molecular
sub getHybridCode {
  my($chars, $genes, $genomePos) = @_;
  my(@c) = split(/\:/, $chars);
  my(@g) = split(/\:/, $genes);
  my $code = "S"; # intra molecular by default.
  my(@prefix) = @g; #copy array
  # try to get gene families..
  for(my $i=0; $i < scalar(@prefix); $i++) {
    if(defined($GENEFAM{$prefix[$i]})) {  #subst with gene family
      $prefix[$i] = $GENEFAM{$prefix[$i]};
    } else {  # gene fam not identified, try symbol prefix
      my(@c) = split(/[\d\-]/, $prefix[$i]);
      $prefix[$i] = $c[0]; 
    }
  }
  # now test if it is gene family intra-molecular
  my $geneFamStruc = join(":", @prefix);  
  my $testStruc = $geneFamStruc;
  for(my $i=0; $i < scalar(@prefix); $i++) {
    my $fam = $prefix[$i];
    $testStruc =~ s/\b$fam\b/$i/g;
  }
  if($chars =~ /B/) {  #possibly inter-molecular
    $code = ($testStruc =~ /1/) ? "I" : "R";  # set code 
  }
  $code = "A" if ($chars =~ /\-/); # antisense; #TODO TEST
  # check overlap of genomePos
  if($genomePos) {
    my(@pos) = split(/\,/, $genomePos);
    my $overlap = 0;
    my $compNum = 0;
    for(my $i=0; $i < scalar(@pos) - 1; $i++) {
      next if $pos[$i] eq "NA";
      my($aChr, $aPos, $aRan) = split(/\:/, $pos[$i]);
      my $aCoord = [$aChr, $aPos-$COORDEXPAND, $aPos+$COORDEXPAND, $aRan];
      for(my $j = $i+1; $j < scalar(@pos); $j++) {
        next if $pos[$j] eq "NA";
        $compNum++;
        my($bChr, $bPos, $bRan) = split(/\:/, $pos[$j]);
        my $bCoord = [$bChr, $bPos-$COORDEXPAND, $bPos+$COORDEXPAND, $bRan];
        $overlap++ if coorOverlap($aCoord, $bCoord);
      }
    }
    if($overlap == $compNum and $overlap > 0 and $code ne "A") { # then this is the same locus
      $code = "S"; #TODO TEST
    }
  }
  return($code, $geneFamStruc);
}


# compare two alignments first by alignment score
# then by symbol and biotypes.
sub alignCmp {
  my($alignA, $alignB) = @_;
  
  # explode if neither is defined.
  explode "Invalid object $alignA or $alignB!" unless defined($alignA or $alignB);
  return -1 unless defined($alignA); # a is defined but b is not
  return 1 unless defined($alignB); # b is defined by a is not

  my $cmp = ($alignA->[0] <=> $alignB->[0]); #alignment score
  return($cmp) if $cmp != 0;
  $cmp = ($alignB->[2] <=> $alignA->[2]); #length of alignment
  return($cmp) if $cmp != 0;
  # bias against hybrids when vs non-hybrids
  if($alignA->[5] =~ /\:\-\:/ and $alignB->[5] !~ /\:\-\:/) { return -1; }
  if($alignA->[5] !~ /\:\-\:/ and $alignB->[5] =~ /\:\-\:/) { return 1; }
  # if both are hybrids
  if($alignA->[5] =~ /\:\-\:/ and $alignB->[5] =~ /\:\-\:/) {
    my(@splA) = split(/\:\-\:/, $alignA->[5]);
    my(@splB) = split(/\:\-\:/, $alignB->[5]);
    $cmp = (scalar @splB <=> scalar @splA); # prefer less ligation sites
    return($cmp) if $cmp != 0;
    my(%uniqA, %uniqB);
    foreach my $id (@splA) { $uniqA{$id} = 1; }
    foreach my $id (@splB) { $uniqB{$id} = 1; }
    $cmp = (scalar(keys %uniqA) <=> scalar(keys %uniqB)); # prefer intra-molecular
    return $cmp;
  }
  # look at symbol and biotype
  my(undef, undef, $symA, $biotypeA) = split(/\_/, $alignA->[5]);
  my(undef, undef, $symB, $biotypeB) = split(/\_/, $alignB->[5]);
  $cmp = (isOverAbundant($symA) <=> isOverAbundant($symB)); #is overabundant?
  return($cmp) if $cmp != 0;
  $cmp = (biorank($biotypeA) <=> biorank($biotypeB)); # biotype ranking
  return($cmp) if $cmp != 0;
  $cmp = (length($symB) <=> length($symA)); # gene symbol length
  return($cmp) if $cmp != 0;
  $cmp = ($symA cmp $symB); # finally lexographical gene symbol
  return $cmp;
}

# rank biotype by..
sub biorank {
  my $biotype = shift;
  return 6 if ($biotype eq "misc-RNA");
  return 5 if ($biotype =~ /RNA/);
  return 3 if ($biotype =~ /intron/);
  return 2 if ($biotype !~ /protein-coding/);
  return 4;
}

# score over abundant symbols highest
sub isOverAbundant {
  my($name) = @_;;
  my $ret = 0;
  $ret += ($name =~ /ncrna|RNA|sno|5S|SNOR|Y-RNA|RNY|U\d|miR|piR/) ? 1 : 0;
  $ret += ($name =~ /RN7|7SL|7SK|SRP|MRP|RPPH|RNase/) ? 2 : 0;
  return $ret;
}

__END__
