#!/usr/bin/env perl

use FindBin;
use lib "$FindBin::Bin";
use discipline;

use Cwd qw(abs_path);
use File::Basename qw(dirname);
use Getopt::Long;
use File::Path qw(make_path);
use File::Spec::Functions;
use File::Find::Rule;

use illumina_template qw(from_template);


my $settingsDir = catfile(dirname(abs_path($0)), "settings");
exit interactive() if @ARGV == 0;

GetOptions("iniFile|i=s" => \my $iniFile,
           "iniPath|ip=s" => \my $iniPath,
           "outputDir|o=s" => \my $outputDir,
           "fastqDir|f=s" => \my @fastqDirs,
           "bamDir|b=s" => \my @bamDirs,
           "vcfFile|v=s" => \my $vcfFile,
           "mail|m=s" => \my $mail,
           "help|h" => \my $help,
           "run" => \my $run
          )
or die usage();

usage() if $help || !($iniFile || $iniPath) || !$outputDir || !(@fastqDirs || @bamDirs || $vcfFile) || !$mail;

my $ini;
if ($iniFile) {
    $ini = catfile($settingsDir, $iniFile);
} elsif ($iniPath) {
    $ini = $iniPath;
}
say "ERROR: $ini does not exist." if !-f $ini;

exit createConfig($ini, $outputDir, \@fastqDirs, \@bamDirs, $vcfFile, $mail, $run);


sub getIniFiles {
    my ($iniDir) = @_;

    -d $iniDir or die "Can't get INI files from $iniDir: $!";
    my @iniFiles = File::Find::Rule->file()
        ->name("*.ini")
        ->in($iniDir);
    while (my ($iniIndex, $iniFile) = each @iniFiles) {
        say "\t${iniIndex}:\t${iniFile}";
    }
    return \@iniFiles;
}

sub createConfig {
    my ($iniFile, $outputDir, $fastqDirs, $bamDirs, $vcfFile, $mail, $run) = @_;

    if (!-d $outputDir) {
        make_path($outputDir) or die "Couldn't create directory $outputDir: $!";
    }

    map { die "$_ does not exist" if not -d } @{$fastqDirs};
    map { die "$_ does not exist" if not -d } @{$bamDirs};
    die "$vcfFile does not exist" if $vcfFile and not -f $vcfFile;

    my @fastqFiles = File::Find::Rule->file()
        ->name("*.fastq.gz")
        ->in(@{$fastqDirs});
    my @bamFiles = File::Find::Rule->file()
        ->name("*.bam")
        ->in(@{$bamDirs});

    my $configFile = catfile($outputDir, "settings.config");
    from_template("Config.tt", $configFile,
                  iniFile => $iniFile,
                  outputDir => $outputDir,
                  mail => $mail,
                  fastqFiles => \@fastqFiles,
                  bamFiles => \@bamFiles,
                  vcfFiles => [$vcfFile]);

    if ($run) {
        my $pipeline = catfile(dirname(abs_path($0)), "illumina_pipeline.pl");
        return system "$pipeline $configFile";
    }
    return 0;
}

sub usage {
    say "Usage: perl illumina_createConfig.pl";
    say "";
    say "Advanced usage:";
    say "illumina_createConfig.pl REQUIRED_ARGUMENTS [-run]";
    say "";
    say "Required INI file:";
    say "";
    say "\t-i, --inifile settings.ini";
    say "\t-ip, --inipath /path/to/settings.ini";
    say "";
    say "Required input data:";
    say "";
    say "\t-f, --fastqdir /fastqFolder";
    say "\t-b, --bamdir /bamFolder";
    say "\t-v, --vcfFile vcfFile.vcf";
    say "";
    say "Required output config:";
    say "";
    say "\t-o, --outputdir /path/to/outputDir";
    say "\t-m, --mail example\@mail.nl";
    say "";
    say "Available INI files: (use -i)";
    getIniFiles($settingsDir);
    exit;
}

sub interactive {
    say "Using interactive mode";
    say "Available INI files:";
    my @iniFiles = @{getIniFiles($settingsDir)};

    print "Choose setting file [index]: ";
    chomp(my $iniIndex = <>);
    die "Please provide a correct INI index number" unless $iniIndex and $iniFiles[$iniIndex];
    my $iniFile = catfile($settingsDir, "$iniFiles[$iniIndex]");

    print "Output dir: ";
    chomp($outputDir = <>);
    die "Please provide a correct output directory" unless $outputDir;

    print "Input FASTQ data dir: ";
    chomp(my $rawDataDir = <>);
    push @fastqDirs, $rawDataDir if $rawDataDir;

    print "Input BAM data dir: ";
    chomp($rawDataDir = <>);
    push @bamDirs, $rawDataDir if $rawDataDir;

    die "Please provide a correct input data directory" unless @fastqDirs or @bamDirs;

    print "Input VCF: ";
    chomp($vcfFile = <>);
    $vcfFile = undef unless $vcfFile;

    print "Mail address: ";
    chomp($mail = <>);
    die "Please provide a correct mail address" unless $mail;

    return createConfig($iniFile, $outputDir, \@fastqDirs, \@bamDirs, $vcfFile, $mail, undef);
}