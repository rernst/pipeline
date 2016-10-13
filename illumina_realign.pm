package illumina_realign;

use 5.16.0;
use strict;
use warnings;

use File::Basename;
use File::Spec::Functions;

use FindBin;
use lib "$FindBin::Bin";

use illumina_sge qw(getJobId jobNative qsubJava qsubTemplate);
use illumina_template qw(from_template);


sub runRealignment {
    my ($opt) = @_;

    say "Running single sample indel realignment for the following BAM-files:";

    my $knownIndelFiles;
    $knownIndelFiles = join " ", map { "-known $_" } split '\t', $opt->{REALIGNMENT_KNOWN} if $opt->{REALIGNMENT_KNOWN};

    foreach my $sample (keys %{$opt->{SAMPLES}}) {
        my $bam = $opt->{BAM_FILES}->{$sample};
        (my $flagstat = $bam) =~ s/\.bam$/.flagstat/;
        (my $realignedBam = $bam) =~ s/\.bam$/.realigned.bam/;
        (my $realignedBai = $bam) =~ s/\.bam$/.realigned.bai/;
        (my $realignedBamBai = $bam) =~ s/\.bam$/.realigned.bam.bai/;
        (my $realignedFlagstat = $bam) =~ s/\.bam$/.realigned.flagstat/;

        (my $healthCheckPreRealignSlicedBam = $bam) =~ s/\.bam$/.qc.prerealign.sliced.bam/;
        (my $healthCheckPreRealignSlicedBamBai = $bam) =~ s/\.bam$/.qc.prerealign.sliced.bam.bai/;
        (my $healthCheckPostRealignSlicedBam = $bam) =~ s/\.bam$/.qc.postrealign.sliced.bam/;
        (my $healthCheckPostRealignSlicedBamBai = $bam) =~ s/\.bam$/.qc.postrealign.sliced.bam.bai/;
        (my $healthCheckPostRealignSlicedFlagstat = $bam) =~ s/\.bam$/.qc.postrealign.sliced.flagstat/;
        (my $healthCheckPrePostRealignDiff = $bam) =~ s/\.bam$/.qc.prepostrealign.diff/;
        (my $cpctSlicedBam = $bam) =~ s/\.bam$/.realigned.sliced.bam/;
        (my $cpctSlicedBamBai = $bam) =~ s/\.bam$/.realigned.sliced.bam.bai/;

        $opt->{BAM_FILES}->{$sample} = $realignedBam;

        say "\t$opt->{OUTPUT_DIR}/${sample}/mapping/${bam}";

        my $done_file = catfile($opt->{OUTPUT_DIR}, $sample, "logs", "Realignment_${sample}.done");
        if (-f $done_file) {
            say "WARNING: $done_file exists, skipping";
            next;
        }

        my $logDir = catfile($opt->{OUTPUT_DIR}, $sample, "logs");
        my $jobIDRealign = "Realign_${sample}_" . getJobId();
        my $bashFile = catfile($opt->{OUTPUT_DIR}, $sample, "jobs", "${jobIDRealign}.sh");
        my $jobNative = jobNative($opt, "REALIGNMENT");

        from_template("Realign.sh.tt", $bashFile,
                      sample => $sample,
                      bam => $bam,
                      logDir => $logDir,
                      jobNative => $jobNative,
                      knownIndelFiles => $knownIndelFiles,
                      healthCheckPreRealignSlicedBam => $healthCheckPreRealignSlicedBam,
                      healthCheckPreRealignSlicedBamBai => $healthCheckPreRealignSlicedBamBai,
                      opt => $opt);

        my $qsub = qsubJava($opt, "REALIGNMENT_MASTER");
        my $stdout = catfile($logDir, "Realignment_${sample}.out");
        my $stderr = catfile($logDir, "Realignment_${sample}.err");
        if (@{$opt->{RUNNING_JOBS}->{$sample}}) {
            my $hold_jids = join ",", @{$opt->{RUNNING_JOBS}->{$sample}};
            system "$qsub -o $stdout -e $stderr -N $jobIDRealign -hold_jid $hold_jids $bashFile";
        } else {
            system "$qsub -o $stdout -e $stderr -N $jobIDRealign $bashFile";
        }

        my $jobIDPostProcess = "RealignPostProcess_${sample}_" . getJobId();
        my $realignPostProcessScript = catfile($opt->{OUTPUT_DIR}, $sample, "jobs", "${jobIDPostProcess}.sh");

        from_template("RealignPostProcess.sh.tt", $realignPostProcessScript,
                      realignedBam => $realignedBam,
                      realignedBai => $realignedBai,
                      realignedBamBai => $realignedBamBai,
                      realignedFlagstat => $realignedFlagstat,
                      flagstat => $flagstat,
                      sample => $sample,
                      bam => $bam,
                      logDir => $logDir,
                      cpctSlicedBam => $cpctSlicedBam,
                      cpctSlicedBamBai => $cpctSlicedBamBai,
                      healthCheckPreRealignSlicedBam => $healthCheckPreRealignSlicedBam,
                      healthCheckPostRealignSlicedBam => $healthCheckPostRealignSlicedBam,
                      healthCheckPostRealignSlicedBamBai => $healthCheckPostRealignSlicedBamBai,
                      healthCheckPostRealignSlicedFlagstat => $healthCheckPostRealignSlicedFlagstat,
                      healthCheckPrePostRealignDiff => $healthCheckPrePostRealignDiff,
                      opt => $opt);

        $qsub = qsubTemplate($opt, "FLAGSTAT");
        $stdout = catfile($logDir, "RealignmentPostProcess_${sample}.out");
        $stderr = catfile($logDir, "RealignmentPostProcess_${sample}.err");
        system "$qsub -o $stdout -e $stderr -N $jobIDPostProcess -hold_jid $jobIDRealign $realignPostProcessScript";

        push @{$opt->{RUNNING_JOBS}->{$sample}}, $jobIDRealign;
        push @{$opt->{RUNNING_JOBS}->{$sample}}, $jobIDPostProcess;
    }
    return;
}

1;
