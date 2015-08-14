a<em>ligate</em>r
=================

Software suite for detection of chimeric or circular RNAs from high-throughput sequencing data.
Designed for use on LIGR-seq data (citation coming..), but can be applied to regular RNAseq for
detection of circular RNAs as well (experimental).

--
The method summarizes as follows:
<div align=center><img src="/lib/overview.png" width="500px" /></div>
--

Table of Contents
-----------------

- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [File Formats](#file-formats)

Requirements
------------

_julia 0.4_
 * ArgParse
 * Match
 * Distributions
 * GZip

_perl v5 Packages_
 * Parallel::ForkManager
 * Getopt::Long

_external software_
 * [bowtie2](http://bowtie-bio.sourceforge.net/bowtie2/manual.shtml) - short-read alignment
 * blastn - `ftp://ftp.ncbi.nlm.nih.gov/blast/executables/blast+/LATEST/`
 * blast databses `ftp://ftp.ncbi.nlm.nih.gov/blast/db/`: nr, human_genomic, other_genomic 

_optional_
 * [RactIP](http://rtips.dna.bio.keio.ac.jp/ractip/) - intermolecular _in silico_ RNA folding
 * [nibFrag](http://hgdownload.soe.ucsc.edu/admin/exe/) - faToNib to make nib genome files from fasta format
 * [faToNib](http://hgdownload.soe.ucsc.edu/admin/exe/) - nibFrag to quickly retrieve sequences from nib formatted chromosomes
 

Installation
------------

- [System](#system)
- [Database Setup](#database-setup)

###System###

If you are new to `julia`, the latest 0.4-dev binaries can be downloaded from the nightly builds [64-bit](https://status.julialang.org/download/linux-x86_64) or [32-bit](https://status.julialang.org/download/linux-i686).  The packages can then be installed manually by opening the `julia` REPL:
```julia
  pkgs = ("ArgParse", "Match", "Distributions", "GZip")
  map( x->Pkg.add(x), pkgs ) 
```
The `perl` packages can be installed using `cpan -i Parallel::ForkManager`

###Database Setup###

The current database is for hg19, you can download it here: [hg19 transcriptome](http://google.com)

It is also possible to use a different build or species, but automation of this process is still in development, so you should e-mail me for a synopsis of the required steps.  


Usage
-----

- [Alignment and Detection](#alignment-and-detection)
- [Post Processing](#post-processing)
- [Reclassification](#reclassification)
- [Statistics](#statistics)

The aligater executable is a wrapper for a set of tools that are meant to work
as input/output for one another, often compatible with piping one into the next.
```bash
$ aligater -h
     aligater [sub-command] [-h]
         - align   : align short-reads to transcriptome
         - detect  : detect chimeric reads by recursive chaining of transcriptome SAM blocks
         - post    : post-process LIG format files with BLAST or RACTIP
         - reclass : create 2D k-mer db and reclassify chimeras using heirarchical type
         - stats   : compare crosslinked to mock-treated samples using multinomial statistics
         - table   : compile interaction results into tabular format
```

###Alignment and Detection###

Using the default alignment parameters is recommended for LIGR-seq and the step
can be run as simply as:
```bash
$ filename="somefile.fastq.gz"
$ nodir=`basename $filename`
$ prefastq=${nodir%%.*}

$ aligater align -x db $filename > sam/$prefastq.sam
```
or `--bam` flag will pipe the output of aligater align into `samtools view -bS`

But feel free to alter other alignment parameters as you see fit for custom purposes:
```bash
$ aligater align -h
```

The next step is detection, which can be piped from the first: `aligater align | aligater detect > out.lig`
```bash
$ detectparam='--gtf [annoFile.gtf(.gz)] --gfam [gene_fam.txt(.gz)] --rmsk [maskerFile.bed(.gz)]'
$ aligater detect $detectparam < sam/$prefastq.sam > lig/$prefastq.lig
```
will print a [lig formatted](#file-formats) file to STDOUT.

or if bam output was specified from the first command.
```bash
$ samtools view -h bam/$prefastq.bam | aligater detect $detectparam > lig/$prefastq.lig
```

###Post Processing###

There are a few parts to the post processing step, a number of filtering flags, a `--blast` (mandatory) step and a folding step using `--ractip` (optional), each requiring the use of external dependencies (installed to your `$path`), `blastn` and `ractip`, see [requirements](#requirements).

```bash
aligater post [filtering_flags] [--blast] [--ractip] 
```

It is recommended that these commands be run separately, to effectively make use system resources. 
For example, `--ractip` takes several hours with substantial CPU on multiple cores (`-p`), but doesn't require much RAM.  
Meanwhile, `--blast` is very CPU heavy and requires significant RAM as well!

The first command `aligater post --blast` should be considered mandatory, it is *not* recommended to skip this step.
This step requires proper installation of `blastn` and the blast databases to the environmental variable `BLASTDB`.

```bash
$ export BLASTDB="/path/to/blast/databases"
$ blastn -version
blastn: 2.2.28+
Package: blast 2.2.28, build Mar 12 2013 16:52:31

$ aligater post [--tmp (def: /tmp/aligater)] [-p] --loose --blast < lig/$prefastq.lig > lig/$prefastq.blast.lig
```
Edit the `tmp` directory to hit and number of threads `-p` to use as necessary.


###Reclassification###

This is a two part step, you need to first create a junction library `.jlz` from the
annotations of all samples and replicates that you plan to compare:
```bash
$ aligater reclass --uniq --save database.jlz < lig/*blast.filtered.lig
```

and then the actual reclassification step on each `lig` file:
```bash
$ aligater reclass --load database.jlz -g -b -u < lig/$input.lig > lig/$input.reclass.lig
```

###Statistics###

This step produces the final output of the `aligater` package and takes a number of command line options that require that the input file names be properly formatted! 

The input expects two foreground files, a crosslinking reagent treated (xlink) or mock-treated/control (unxlink) which are identical file names other than some specific identifier that you could specify as a wildcard. For example:

```bash
$ xlinkfile="sample_rep1-xlink.final.lig"
$ unxlinkfile="sample_rep1-unx.final.lig"

$ foregroundfile="sample_rep1-%.final.lig"
```
along with an `--nd xlink,unx` flag which specifies the strings to insert into the `%` wildcard to make the two input files.

Similarly, the two background files containing non-chimeric expression level `.lig` files must be similarly formatted with a `%` wildcard that will be interpolated with the same `--nd` strings.
```bash
$ backgroundfile="sample_rep1-%.expression.lig"

$ nameParam="--fore $foregroundfile --back $backgroundfile --nd xlink,unx"
```

Additionally we have to supply the comma delimited normalization constants (total fastq input read numbers) `--nc` for the foreground files:
```bash
$ totalAMTreads=73217814
$ totalMOCKreads=62648851

$ normParam="--nc $totalAMTreads,$totalMOCKreads"
```

This makes up the core mandatory arguments to `aligater stats`:
```bash
$ aligater stats $nameParam $normParam > output.pvl
```

However there are a number of other optional arguments which can greatly expand the data compiled by `aligater stats` such as the `--vs` option which allows an arbitrary number of variable columns to summarize for each interaction 'col:type,col:type,etc..'.  Each entry consists of a column number (1-based) followed by a `:` and a data type character `[pcfdn]` where each character stands for:
 * `p` : paired column with colon delimited entries for example BIOTYPEA:BIOTYPEB
 * `c` : character containing column to include
 * `f` : floating point number within the scope of Float64
 * `d` : integer number within the scope of Int64
 * `n` : some member of the Number abstract type, could be complex
 
For `lig` format you can use: `--vs 18:f,24:p,21:f,22:d,23:d` which should summarize most of the important columns.

Additionally there is a `--filt` optional flag that can be used to specify a single column and regex pattern for filtering purposes.  For example you may want to filter for only intermolecular interactions using `--filt 1:I`.


