#!/usr/bin/env perl
#
##
##  Author: Tim Sterne-Weiler, timbitz (Oct 2014)
##  e-mail: tim.sterne.weiler@utoronto.ca
##

use warnings;
use strict;

use Cwd qw(abs_path);
use Digest::MD5 qw(md5_hex md5_base64);

use FindBin;
use lib "$FindBin::Bin/../lib";

use Getopt::Long;

use SamBasics qw(:all);
use FuncBasics qw(randomSeedRNG max min);
use SequenceBasics qw(gcContent);

# INITIALIZE
my $path = abs_path($0);
$0 =~ s/^.*\///;
$path =~ s/\/$0$//;

my $tmpPath = "$path/../tmp";
my $libPath = "$path/../lib";

my %toFilter;  #main memory use of the program

# GLOBAL INIT
my $STRICT = 1;
my $RUNBLAST = 0;
my $RUNRACTIP = 0;

my $blastDb = "human_genomic,other_genomic,nt";

my $bpMonoLimit = 7;
my $gcLimit = 0.8;

my $threads = 1;

GetOptions("gc=f" => \$gcLimit, 
           "mono=i" => \$bpMonoLimit,
           "p=i" => \$threads, 
           "ractip" => \$RUNRACTIP,
           "blast" => \$RUNBLAST);

# don't die, explode!
sub explode {
  my $str = shift;
  chomp($str);
  die "[aligater post]: (Input Line $.) ERROR $str\n";
}

sub reverb {
  my $str = shift;
  chomp($str);
  print STDERR "[$0]: ($.) $str\n";
}

sub checkSoft {
  my $prog = shift;
  system("bash", "-c", "which $prog > /dev/null 2> /dev/null") and
              explode "Cannot find $prog which is required!\n";
}

# make sure another instance doesn't try to write to the same files...
randomSeedRNG(); # srand `time ^ $$ ^ unpack "%L*", `ps axww | gzip`;
my $rand = substr(md5_hex(rand), 0, 6);


## CHECK IF SOFTWARE IS INSTALLED ------------------------#
if($RUNBLAST) {
  # check if blastn is installed and BLASTDB is set in ENV;
  checkSoft("blastn");
  explode "BLASTDB environmental variable must be set!\n" unless defined($ENV{"BLASTDB"});
 
  open(FORBLAST, ">$tmpPath/tmp_$rand.fa") or die "Can't open tmp/tmp_$rand.fa for writing!\n";
}
if($RUNRACTIP) {
  checkSoft("ractip");
  my(undef, $racVer) = split(/\s|\./, `ractip -V`);
  explode "ractip version must be > 1.0.0 !" unless $racVer >= 1;
}
#---------------------------------------------------------#

# main loop, collect relevant entries and store into memory if --blast
while(my $l = <>) {
  chomp($l);
  my(@a) = split(/\t/, $l);

  my $seq = $a[8]; 
  my $gcContent = gcContent($seq);

  # HARD FILTERS ----------------------#
  # mononucleotide tract filter
  next if($seq =~ /[Aa]{$bpMonoLimit}|[Tt]{$bpMonoLimit}|[Cc]{$bpMonoLimit}|[Gg]{$bpMonoLimit}/);
  next if length($seq) < 44; # need at least 22bp on either side.
  next if $gcContent >= $gcLimit; # greater than limit of gc content
  #------------------------------------#

  my($seqA, $seqB) = split(/\_/, $seq); 

  my($dG, $strA, $strB, $len, $amt) = runRactIP($seqA, $seqB, "$libPath/rna_andronescu2007.par");
  my($dG_ua, $strA_ua, $strB_ua, $len_ua) = runRactIP($seqA, $seqB, "$libPath/rna_andronescu2007_ua.par");
  my $altStruc = ($strA eq $strA_ua and $strB eq $strB_ua) ? "no" : "yes";
  my $altDG = (abs($len - $len_ua) <= 1) ? $dG_ua - $dG : 0;
  print ">>$dG\n$strA\t$strB\n$seqA\t$seqB\n$len\t$amt\t$altDG>>>>\n";
 
} # end main loop
close FORBLAST;


if($RUNBLAST) { # lets run blast and remove ligations that aren't unique.
  foreach my $db (split(/\,/, $blastDb)) {
    runBlastn($db, "tmp_$rand", $threads);
    openBlastOutAndRemoveHits("$tmpPath/tmp_$rand.$db.out");
  }
  system("rm $tmpPath/tmp_$rand.*");
}

# now print the remaining results.

#######################################################
#                                                     #
######            BEGIN SUBROUTINES            ########
#                                                     #
#######################################################

# this function runs the RactIP program for RNA-RNA interaction prediction
# using dynamic programming using the -e parameter and an optional -P param file
# returned are: deltaG, the first structure (bracket notation), second structure,
# followed by the maximum intermolecular interaction stem length ( [[[[[ or ]]]]] )
# this doesn't yet make use of the z-score function or check that the program is
# properly installed or of the correct version
sub runRactIP {
  my($seqA, $seqB, $param) = @_;
  $seqA =~ s/T/U/g if($seqA =~ /T/);
  $seqB =~ s/T/U/g if($seqB =~ /T/);
  my $rand = substr(md5_hex(rand), 0, 4);   
  system("echo \">seqA\n$seqA\" > $tmpPath/$rand\_seqA.fa"); 
  system("echo \">seqB\n$seqB\" > $tmpPath/$rand\_seqB.fa");
  $param = defined($param) ? "-P $param" : "";
  my(@res) = `ractip $tmpPath/$rand\_seqA.fa $tmpPath/$rand\_seqB.fa -e $param`;
  system("rm $tmpPath/$rand*");
  chomp @res;
  my($structA, $structB) = ($res[2], $res[5]); #set structures
  $res[6] =~ /JS\= ([\d\-\.]+)/;
  my $deltaG = $1; # parse energy
  my(@strA) = split(/(?<=\.)(?=[\]\[\(\)])|(?<=[\]\[])(?=[\.\(\)])|(?<=[\(\)])(?=[\.\[\]])/, $structA);
  my(@strB) = split(/(?<=\.)(?=[\]\[\(\)])|(?<=[\]\[])(?=[\.\(\)])|(?<=[\(\)])(?=[\.\[\]])/, $structB);
  my $maxInterLenA = maxLength(\@strA, "[\\[\\]]");
  my $maxInterLenB = maxLength(\@strB, "[\\[\\]]");
  my $maxInterLen = max($maxInterLenA, $maxInterLenB);
  my $amtNum = findUAinStem(\@strA, \@strB, $seqA, $seqB, "[\\[\\]]");
  
  return($deltaG, $structA, $structB, $maxInterLen, $amtNum);
}

# look for diagonal U's in stem given ractip
sub findUAinStem {
  my($structAref, $structBref, $seqA, $seqB, $char) = @_;
  my $intSeqA = "";
  my $revSeqB = "";
  my @stemA;
  my @stemB;
  my $cnt = 0;
  foreach my $seg (@$structAref) {
    ($cnt += length($seg) and next) unless $seg =~ /^$char+$/;
    $intSeqA .= substr($seqA, $cnt, length($seg));
    push(@stemA, "." x length($seg));
    $cnt += length($seg);
  }
  $cnt = 0;
  foreach my $seg (@$structBref) {
    ($cnt += length($seg) and next) unless $seg =~ /^$char+$/;
    $revSeqB .= substr($seqB, $cnt, length($seg));
    push(@stemB, "." x length($seg);
    $cnt += length($seg);
  }
  $revSeqB = reverse scalar $revSeqB;
  print "$intSeqA\n$revSeqB\n";
  my %xlinkPos;
  # now check for diagonal Us,  AB [[ to ]] DC
  #                             .U    to    .U or U. to U.
  for(my $i=0; $i < length($intSeqA) - 1; $i++) {
    my $a = substr($intSeqA, $i, 1);
    my $b = substr($intSeqA, $i+1, 1);
    my $c = substr($revSeqB, $i, 1);
    my $d = substr($revSeqB, $i+1, 1);
    $xlinkPos{$i} = 1 if($a =~ /u|U/ and $d =~ /u|U/);
    $xlinkPos{$i+1} = 1 if($b =~ /u|U/ and $c =~ /u|U/);
  }
  return(scalar(keys %xlinkPos));
}

# used by the runRactIP program.
sub maxLength {
  my($aRef, $char) = @_;
  my $maxLen = 0;
  foreach my $elem (@$aRef) {
    my $l = length($elem);
    next unless $elem =~ /^$char+$/;
    $maxLen = ($l > $maxLen) ? $l : $maxLen;
  }
  return($maxLen);
}

sub runBlastn {
  my($db, $basename, $threads) = @_;
  system("blastn -query $path/../tmp/$basename.fa -task blastn -db $db -word_size 20 \
         -outfmt '6 sseqid sstart send qseqid sstrand pident length qstart qend qseq sseq evalue' \
         -perc_identity 75 -culling_limit 1 -num_threads $threads > $path/../tmp/$basename.$db.out");
}

sub openBlastOutAndRemoveHits {
  my($filename, $filterHash) = @_;
  my $hndl = openFileHandle($filename);
  while(my $l = <$hndl>) {
    my(@a) = split(/\t/, $l);
    my(@b) = split(/\:/, $a[3]); #split name
    if($a[8] - $a[7] < 33) {
      if($a[7] > $b[1] - 8) { next; }
      if($a[8] < $b[2] + 8) { next; }
    }
    delete $toFilter{$b[0]};
  }
}

__END__