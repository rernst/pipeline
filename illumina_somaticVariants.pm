package illumina_somaticVariants;

use strict;
use warnings;
use File::Path qw(make_path);
use lib "$FindBin::Bin";
use illumina_sge;
use illumina_template;
use illumina_metadataParser;

sub runSomaticVariantCallers {
    my $configuration = shift;
    my %opt = %{$configuration};

    my @pileupJobs;

    foreach my $sample (@{$opt{SAMPLES}}) {
        if ($opt{SOMVAR_VARSCAN} eq "yes") {
            print "Creating pileup for: $sample\n";
            my $pileup_job = runPileup($sample, \%opt);
            push(@pileupJobs, $pileup_job);
        }
    }

    $opt{RUNNING_JOBS}->{'pileup'} = \@pileupJobs;

    my $metadata = metadataParse($opt{OUTPUT_DIR});
    my $sample_ref = $metadata->{'ref_sample'};
    my $sample_tumor = $metadata->{'tumor_sample'};

    my @merge_somvar_jobs;
    my @somvar_jobs;

    my $sample_tumor_name = "$sample_ref\_$sample_tumor";
    my $sample_tumor_out_dir = "$opt{OUTPUT_DIR}/somaticVariants/$sample_tumor_name";
    my $sample_tumor_tmp_dir = "$sample_tumor_out_dir/tmp/";
    my $sample_tumor_log_dir = "$sample_tumor_out_dir/logs/";
    my $sample_tumor_job_dir = "$sample_tumor_out_dir/jobs/";

    if (!-e $sample_tumor_out_dir) {
        make_path($sample_tumor_out_dir) or die "Couldn't create directory:  $sample_tumor_out_dir\n";
    }
    if (!-e $sample_tumor_tmp_dir) {
        make_path($sample_tumor_tmp_dir) or die "Couldn't create directory: $sample_tumor_tmp_dir\n";
    }
    if (!-e $sample_tumor_job_dir) {
        make_path($sample_tumor_job_dir) or die "Couldn't create directory: $sample_tumor_job_dir\n";
    }
    if (!-e $sample_tumor_log_dir) {
        make_path($sample_tumor_log_dir) or die "Couldn't create directory: $sample_tumor_log_dir\n";
    }

    my $sample_tumor_bam = "$opt{OUTPUT_DIR}/$sample_tumor/mapping/$opt{BAM_FILES}->{$sample_tumor}";
    my @running_jobs;
    if (@{$opt{RUNNING_JOBS}->{$sample_tumor}}) {
        push(@running_jobs, @{$opt{RUNNING_JOBS}->{$sample_tumor}});
    }
    my $sample_ref_bam = "$opt{OUTPUT_DIR}/$sample_ref/mapping/$opt{BAM_FILES}->{$sample_ref}";
    if (@{$opt{RUNNING_JOBS}->{$sample_ref}}) {
        push(@running_jobs, @{$opt{RUNNING_JOBS}->{$sample_ref}});
    }

    print "\n$sample_tumor_name \t $sample_ref_bam \t $sample_tumor_bam \n";

    if (-e "$sample_tumor_log_dir/$sample_tumor_name.done") {
        print "WARNING: $sample_tumor_log_dir/$sample_tumor_name.done exists, skipping \n";
        next;
    }

    if ($opt{SOMVAR_STRELKA} eq "yes") {
        print "\n###SCHEDULING STRELKA####\n";
        my $strelka_job = runStrelka($sample_tumor, $sample_tumor_out_dir, $sample_tumor_job_dir, $sample_tumor_log_dir
            , $sample_tumor_bam, $sample_ref_bam, \@running_jobs, \%opt);
        if ($strelka_job) {push(@somvar_jobs, $strelka_job)};
    }

    if ($opt{SOMVAR_VARSCAN} eq "yes") {
        print "\n###SCHEDULING VARSCAN####\n";
        my $varscan_job = runVarscan($sample_tumor, $sample_tumor_name, $sample_tumor_out_dir, $sample_tumor_job_dir,
            $sample_tumor_log_dir, $sample_tumor_bam, $sample_ref_bam, \@running_jobs, \%opt);
        if ($varscan_job) {push(@somvar_jobs, $varscan_job)};
    }

    if ($opt{SOMVAR_FREEBAYES} eq "yes") {
        print "\n###SCHEDULING FREEBAYES####\n";
        my $freebayes_job = runFreeBayes($sample_tumor, $sample_tumor_name, $sample_tumor_out_dir,
            $sample_tumor_job_dir, $sample_tumor_log_dir, $sample_tumor_bam, $sample_ref_bam, \@running_jobs, \%opt);
        if ($freebayes_job) {push(@somvar_jobs, $freebayes_job)};
    }

    if ($opt{SOMVAR_MUTECT} eq "yes") {
        print "\n###SCHEDULING MUTECT####\n";
        my $mutect_job = runMutect($sample_tumor, $sample_tumor_name, $sample_tumor_out_dir, $sample_tumor_job_dir,
            $sample_tumor_log_dir, $sample_tumor_bam, $sample_ref_bam, \@running_jobs, \%opt);
        if ($mutect_job) {push(@somvar_jobs, $mutect_job)};
    }

    print "\n###SCHEDULING MERGE SOMATIC VCFS####\n";

    my $job_id = "MERGE_".$sample_tumor."_".getJobId();
    my $bash_file = $sample_tumor_job_dir."/".$job_id.".sh";

    open MERGE_SH, ">$bash_file" or die "cannot open file $bash_file \n";
    print MERGE_SH "#!/bin/bash\n\n";
    print MERGE_SH "echo \"Start Merge\t\" `date` `uname -n` >> $sample_tumor_log_dir/merge.log\n\n";

    my $invcf;
    my $outvcf = "$sample_tumor_out_dir/$sample_tumor_name\_merged_somatics.vcf";
    print MERGE_SH "java -Xmx".$opt{SOMVARMERGE_MEM}."G -Djava.io.tmpdir=$sample_tumor_tmp_dir -jar $opt{GATK_PATH}/GenomeAnalysisTK.jar -T CombineVariants -R $opt{GENOME} -o $outvcf --genotypemergeoption uniquify ";
    if ($opt{SOMVAR_STRELKA} eq "yes") { print MERGE_SH "-V:strelka $sample_tumor_out_dir/strelka/passed.somatic.merged.vcf "; }
    if ($opt{SOMVAR_VARSCAN} eq "yes") { print MERGE_SH "-V:varscan $sample_tumor_out_dir/varscan/$sample_tumor_name.merged.Somatic.hc.vcf "; }
    if ($opt{SOMVAR_FREEBAYES} eq "yes") { print MERGE_SH "-V:freebayes $sample_tumor_out_dir/freebayes/$sample_tumor_name\_somatic_filtered.vcf "; }
    if ($opt{SOMVAR_MUTECT} eq "yes") { print MERGE_SH "-V:mutect $sample_tumor_out_dir/mutect/$sample_tumor_name\_mutect_passed.vcf ";}
    print MERGE_SH "\n\n";

    if ($opt{SOMVAR_TARGETS}) {
        $invcf = $outvcf;
        $outvcf = "$sample_tumor_out_dir/$sample_tumor_name\_filtered_merged_somatics.vcf";
        print MERGE_SH "java -Xmx".$opt{SOMVARMERGE_MEM}."G -Djava.io.tmpdir=$sample_tumor_tmp_dir -jar $opt{GATK_PATH}/GenomeAnalysisTK.jar -T SelectVariants -R $opt{GENOME} -L $opt{SOMVAR_TARGETS} -V $invcf -o $outvcf\n";
        print MERGE_SH "rm $invcf*\n\n";
    }

    my $preAnnotateVCF = $outvcf;

    if ($opt{SOMVAR_ANNOTATE} eq "yes") {
        $invcf = $outvcf;
        $outvcf =~ s/.vcf/_snpEff.vcf/;
        print MERGE_SH "java -Xmx".$opt{SOMVARMERGE_MEM}."G -Djava.io.tmpdir=$sample_tumor_tmp_dir -jar $opt{SNPEFF_PATH}/snpEff.jar -c $opt{SNPEFF_PATH}/snpEff.config $opt{ANNOTATE_DB} -v $invcf $opt{ANNOTATE_FLAGS} > $outvcf\n";

        $invcf = $outvcf;
        my $suffix = "_dbSNP.vcf";
        $outvcf =~ s/.vcf/$suffix/;
        print MERGE_SH "java -Xmx".$opt{SOMVARMERGE_MEM}."G -Djava.io.tmpdir=$sample_tumor_tmp_dir -jar $opt{GATK_PATH}/GenomeAnalysisTK.jar -T VariantAnnotator -nt $opt{SOMVARMERGE_THREADS} -R $opt{GENOME} -o $outvcf --variant $invcf --dbsnp $opt{CALLING_DBSNP} --alwaysAppendDbsnpId\n";
        print MERGE_SH "if [ -s $outvcf ]\n";
        print MERGE_SH "then\n";
        print MERGE_SH "\trm $invcf $invcf.idx\n";
        print MERGE_SH "fi\n";

        $invcf = $outvcf;
        $suffix = "_$opt{ANNOTATE_IDNAME}.vcf";
        $outvcf =~ s/.vcf/$suffix/;
        print MERGE_SH "java -Xmx".$opt{SOMVARMERGE_MEM}."G -Djava.io.tmpdir=$sample_tumor_tmp_dir -jar $opt{GATK_PATH}/GenomeAnalysisTK.jar -T VariantAnnotator -nt $opt{SOMVARMERGE_THREADS} -R $opt{GENOME} -o $outvcf --variant $invcf --dbsnp $opt{ANNOTATE_IDDB} --alwaysAppendDbsnpId\n";
        print MERGE_SH "if [ -s $outvcf ]\n";
        print MERGE_SH "then\n";
        print MERGE_SH "\trm $invcf $invcf.idx\n";
        print MERGE_SH "fi\n\n";
    }

    $invcf = $outvcf;
    my $suffix = "_melted.vcf";
    $outvcf =~ s/.vcf/$suffix/;
    print MERGE_SH "python $opt{PIPELINE_PATH}/scripts/melt_somatic_vcf.py -t $sample_tumor -v $invcf > $outvcf\n\n";

    print MERGE_SH "if [ \"\$(tail -n 1 $preAnnotateVCF | cut -f 1,2)\" = \"\$(tail -n 1 $outvcf | cut -f 1,2)\" -a -s $preAnnotateVCF -a -s $outvcf ]\n";
    print MERGE_SH "then\n";
    print MERGE_SH "\ttouch $sample_tumor_log_dir/$sample_tumor_name.done\n";
    print MERGE_SH "fi\n";
    print MERGE_SH "echo \"END Merge\t\" `date` `uname -n` >> $sample_tumor_log_dir/merge.log\n\n";
    close MERGE_SH;

    my $qsub = &qsubJava(\%opt, "SOMVARMERGE");
    if (@somvar_jobs) {
        system "$qsub -o $sample_tumor_log_dir -e $sample_tumor_log_dir -N $job_id -hold_jid ".join(",",
                @somvar_jobs)." $bash_file";
    } else {
        system "$qsub -o $sample_tumor_log_dir -e $sample_tumor_log_dir -N $job_id $bash_file";
    }
    push(@merge_somvar_jobs, $job_id);

    return \@merge_somvar_jobs;
}

sub runStrelka {
    my ($sample_tumor, $out_dir, $job_dir, $log_dir, $sample_tumor_bam, $sample_ref_bam, $running_jobs, $opt) = (@_);
    my @running_jobs = @{$running_jobs};
    my %opt = %{$opt};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];

    if (-e "$log_dir/strelka.done") {
        print "WARNING: $log_dir/strelka.done, skipping \n";
        return;
    }

    my $job_id = "STR_".$sample_tumor."_".getJobId();
    my $bash_file = $job_dir."/".$job_id.".sh";

    from_template("Strelka.sh.tt", "$bash_file", runName => $runName, out_dir => $out_dir, sample_ref_bam =>
        $sample_ref_bam, sample_tumor_bam                => $sample_tumor_bam, log_dir => $log_dir, opt => \%opt);

    my $qsub = &qsubJava(\%opt, "STRELKA");
    if (@running_jobs) {
        system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @running_jobs)." $bash_file";
    } else {
        system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
    }

    return $job_id;
}

sub runPileup {
    my ($sample, $configuration) = (@_);
    my %opt = %{$configuration};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];

    my $bam = $opt{BAM_FILES}->{$sample};
    (my $pileup = $bam) =~ s/\.bam/\.pileup/;
    my $jobID = "PILEUP_$sample\_".getJobId();

    if (-e "$opt{OUTPUT_DIR}/$sample/logs/Pileup_$sample.done") {
        print "\t WARNING: $opt{OUTPUT_DIR}/$sample/logs/Pileup_$sample.done exists, skipping\n";
        return $jobID;
    }

    my $logDir = $opt{OUTPUT_DIR}."/".$sample."/logs";
    my $bashFile = $opt{OUTPUT_DIR}."/".$sample."/jobs/".$jobID.".sh";

    from_template("PileUp.sh.tt", "$bashFile", sample => $sample, bam => $bam, pileup => $pileup, runName => $runName,
        opt                                           => \%opt);

    my $qsub = &qsubTemplate(\%opt, "PILEUP");
    if (@{$opt{RUNNING_JOBS}->{$sample}}) {
        system "$qsub -o $logDir/Pileup_$sample.out -e $logDir/Pileup_$sample.err -N $jobID -hold_jid ".join(",",
                @{$opt{RUNNING_JOBS}->{$sample}})." $bashFile";
    } else {
        system "$qsub -o $logDir/Pileup_$sample.out -e $logDir/Pileup_$sample.err -N $jobID $bashFile";
    }
    return $jobID;
}

sub runVarscan {
    my ($sample_tumor, $sample_tumor_name, $out_dir, $job_dir, $log_dir, $sample_tumor_bam, $sample_ref_bam, $running_jobs, $opt) = (@_);
    my %opt = %{$opt};
    my @running_jobs = @{$running_jobs};
    push(@running_jobs, @{$opt{RUNNING_JOBS}->{'pileup'}});
    my $varscan_out_dir = "$out_dir/varscan";
    (my $sample_tumor_pileup = $sample_tumor_bam) =~ s/\.bam/\.pileup\.gz/;
    (my $sample_ref_pileup = $sample_ref_bam) =~ s/\.bam/\.pileup\.gz/;

    if (!-e $varscan_out_dir) {
        make_path($varscan_out_dir) or die "Couldn't create directory: $varscan_out_dir\n";
    }

    if (-e "$log_dir/varscan.done") {
        print "WARNING: $log_dir/varscan.done exists, skipping \n";
        return;
    }

    my $dictFile = $opt{GENOME};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];
    $dictFile =~ s/.fasta$/.dict/;
    my @chrs = @{get_chrs_from_dict($dictFile)};
    my @varscan_jobs;

    foreach my $chr (@chrs) {
        my $job_id = "VS_".$sample_tumor."_".$chr."_".getJobId();
        my $bash_file = $job_dir."/".$job_id.".sh";
        my $output_name = $sample_tumor_name."_".$chr;

        from_template("Varscan.sh.tt", "$bash_file", chr => $chr, output_name => $output_name, varscan_out_dir =>
            $varscan_out_dir, log_dir                    => $log_dir, sample_ref_pileup => $sample_ref_pileup,
            sample_tumor_pileup                          => $sample_tumor_pileup, runName => $runName, opt => \%opt);

        my $qsub = &qsubJava(\%opt, "VARSCAN");
        if (@running_jobs) {
            system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @running_jobs)." $bash_file";
        } else {
            system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
        }

        push(@varscan_jobs, $job_id);
    }

    my $job_id = "VS_".$sample_tumor."_".getJobId();
    my $bash_file = $job_dir."/".$job_id.".sh";

    my $file_test = "if [ -s $sample_ref_bam -a -s $sample_tumor_bam ";
    my $snp_concat_command = "$opt{VCFTOOLS_PATH}/vcf-concat ";
    my $indel_concat_command = "$opt{VCFTOOLS_PATH}/vcf-concat ";
    my $rm_command = "rm ";

    foreach my $chr (@chrs) {
        my $snp_output = $sample_tumor_name."_".$chr.".snp.vcf";
        my $indel_output = $sample_tumor_name."_".$chr.".indel.vcf";
        $file_test .= "-a -s $snp_output -a -s $indel_output ";
        $snp_concat_command .= "$snp_output ";
        $indel_concat_command .= "$indel_output ";
        $rm_command .= "$snp_output $indel_output ";
    }

    $file_test .= "]";
    $snp_concat_command .= "> $sample_tumor_name.snp.vcf";
    $indel_concat_command .= "> $sample_tumor_name.indel.vcf";

    from_template("VarscanPS.sh.tt", "$bash_file", varscan_out_dir => $varscan_out_dir, file_test => $file_test,
        sample_ref_pileup                                          => $sample_ref_pileup, sample_tumor_pileup =>
        $sample_tumor_pileup, sample_tumor_name                    => $sample_tumor_name, rm_command => $rm_command,
        snp_concat_command                                         => $snp_concat_command, indel_concat_command =>
        $indel_concat_command, log_dir                             => $log_dir, runName => $runName, opt => \%opt);

    my $qsub = &qsubJava(\%opt, "VARSCAN");
    if (@varscan_jobs) {
        system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @varscan_jobs)." $bash_file";
    } else {
        system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
    }
    return $job_id;
}

sub runFreeBayes {
    my ($sample_tumor, $sample_tumor_name, $out_dir, $job_dir, $log_dir, $sample_tumor_bam, $sample_ref_bam, $running_jobs, $opt) = (@_);
    my @running_jobs = @{$running_jobs};
    my %opt = %{$opt};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];
    my $freebayes_out_dir = "$out_dir/freebayes";
    my $freebayes_tmp_dir = "$out_dir/freebayes/tmp";

    if (!-e $freebayes_out_dir) {
        make_path($freebayes_out_dir) or die "Couldn't create directory: $freebayes_out_dir\n";
    }
    if (!-e $freebayes_tmp_dir) {
        make_path($freebayes_tmp_dir) or die "Couldn't create directory: $freebayes_tmp_dir\n";
    }

    if (-e "$log_dir/freebayes.done") {
        print "WARNING: $log_dir/freebayes.done exists, skipping \n";
        return;
    }

    my $dictFile = $opt{GENOME};
    $dictFile =~ s/.fasta$/.dict/;
    my @chrs = @{get_chrs_from_dict($dictFile)};
    my @freebayes_jobs;

    foreach my $chr (@chrs) {
        my $job_id = "FB_".$sample_tumor."_".$chr."_".getJobId();
        my $bash_file = $job_dir."/".$job_id.".sh";
        my $output_name = $sample_tumor_name."_".$chr;

        my $freebayes_command = "$opt{FREEBAYES_PATH}/freebayes -f $opt{GENOME} -r $chr ";
        $freebayes_command .= "$opt{FREEBAYES_SETTINGS} $sample_ref_bam $sample_tumor_bam > $freebayes_out_dir/$output_name.vcf";

        my $sort_uniq_filter_command = "$opt{VCFTOOLS_PATH}/vcf-sort -c -t $freebayes_tmp_dir $freebayes_out_dir/$output_name.vcf | $opt{VCFLIB_PATH}/vcfuniq > $freebayes_out_dir/$output_name.sorted_uniq.vcf";
        my $mv_command;
        if ($opt{SOMVAR_TARGETS}) {
            $sort_uniq_filter_command .= "\n\tjava -Xmx".$opt{FREEBAYES_MEM}."G -jar $opt{GATK_PATH}/GenomeAnalysisTK.jar -T SelectVariants -R $opt{GENOME} -L $opt{SOMVAR_TARGETS} -V $freebayes_out_dir/$output_name.sorted_uniq.vcf -o $freebayes_out_dir/$output_name.sorted_uniq_targetfilter.vcf\n";
            $mv_command = "mv $freebayes_out_dir/$output_name.sorted_uniq_targetfilter.vcf $freebayes_out_dir/$output_name.vcf";
        } else {
            $mv_command = "mv $freebayes_out_dir/$output_name.sorted_uniq.vcf $freebayes_out_dir/$output_name.vcf";
        }

        from_template("Freebayes.sh.tt", "$bash_file", chr => $chr, freebayes_command => $freebayes_command,
            sort_uniq_filter_command                       => $sort_uniq_filter_command, mv_command => $mv_command,
            freebayes_out_dir                              => $freebayes_out_dir, sample_tumor_bam => $sample_tumor_bam
            , sample_ref_bam                               => $sample_ref_bam, log_dir => $log_dir, runName => $runName
            , opt                                          => \%opt);

        my $qsub = &qsubJava(\%opt, "FREEBAYES");
        if (@running_jobs) {
            system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @running_jobs)." $bash_file";
        } else {
            system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
        }

        push(@freebayes_jobs, $job_id);
    }

    my $job_id = "FB_".$sample_tumor."_".getJobId();
    my $bash_file = $job_dir."/".$job_id.".sh";

    my $file_test = "if [ -s $sample_ref_bam -a -s $sample_tumor_bam ";
    my $concat_command = "$opt{VCFTOOLS_PATH}/vcf-concat ";
    my $rm_command = "rm -r $freebayes_tmp_dir ";
    foreach my $chr (@chrs) {
        my $snp_output = $sample_tumor_name."_".$chr;
        $file_test .= "-a -s $snp_output\.vcf ";
        $concat_command .= "$snp_output\.vcf ";
        $rm_command .= "$snp_output\* ";
    }
    $file_test .= "]";
    $concat_command .= "> $sample_tumor_name.vcf";

    from_template("FreebayesPostProcess.sh.tt", "$bash_file", file_test => $file_test, concat_command =>
        $concat_command, rm_command                                     => $rm_command, sample_ref_bam =>
        $sample_ref_bam, sample_tumor_bam                               => $sample_tumor_bam, freebayes_out_dir =>
        $freebayes_out_dir, sample_tumor_name                           => $sample_tumor_name, log_dir => $log_dir,
        runName                                                         => $runName, opt => \%opt);

    my $qsub = &qsubJava(\%opt, "FREEBAYES");
    if (@freebayes_jobs) {
        system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @freebayes_jobs)." $bash_file";
    } else {
        system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
    }
    return $job_id;
}

sub runMutect {
    my ($sample_tumor, $sample_tumor_name, $out_dir, $job_dir, $log_dir, $sample_tumor_bam, $sample_ref_bam, $running_jobs, $opt) = (@_);
    my @running_jobs = @{$running_jobs};
    my %opt = %{$opt};
    my $runName = (split("/", $opt{OUTPUT_DIR}))[-1];
    my $mutect_out_dir = "$out_dir/mutect";
    my $mutect_tmp_dir = "$mutect_out_dir/tmp";

    if (!-e $mutect_out_dir) {
        make_path($mutect_out_dir) or die "Couldn't create directory: $mutect_out_dir\n";
    }
    if (!-e $mutect_tmp_dir) {
        make_path($mutect_tmp_dir) or die "Couldn't create directory: $mutect_tmp_dir\n";
    }

    if (-e "$log_dir/mutect.done") {
        print "WARNING: $log_dir/mutect.done, skipping \n";
        return;
    }

    my $dictFile = $opt{GENOME};
    $dictFile =~ s/.fasta$/.dict/;
    my @chrs = @{get_chrs_from_dict($dictFile)};
    my @mutect_jobs;

    foreach my $chr (@chrs) {
        my $job_id = "MUT_".$sample_tumor."_".$chr."_".getJobId();
        my $bash_file = $job_dir."/".$job_id.".sh";
        my $output_name = $sample_tumor_name."_".$chr;

        my $command = "java -Xmx".$opt{MUTECT_MEM}."G -jar $opt{MUTECT_PATH}/mutect.jar -T MuTect ";
        $command .= "-R $opt{GENOME} --cosmic $opt{MUTECT_COSMIC} --dbsnp $opt{CALLING_DBSNP} --intervals $chr ";
        #if ( $opt{SOMVAR_TARGETS} ) {$command .= "--intervals $opt{SOMVAR_TARGETS} ";}
        $command .= "--input_file:normal $sample_ref_bam --input_file:tumor $sample_tumor_bam ";
        $command .= "--out $output_name\.out --vcf $output_name\_mutect.vcf";

        from_template("Mutect.sh.tt", "$bash_file", command => $command, chr => $chr, mutect_tmp_dir => $mutect_tmp_dir
            , sample_tumor_bam                              => $sample_tumor_bam, sample_ref_bam => $sample_ref_bam,
            log_dir                                         => $log_dir, runName => $runName, opt => \%opt);

        my $qsub = &qsubJava(\%opt, "MUTECT");
        if (@running_jobs) {
            system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @running_jobs)." $bash_file";
        } else {
            system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
        }
        push(@mutect_jobs, $job_id);
    }

    my $job_id = "MUT_".$sample_tumor."_".getJobId();
    my $bash_file = $job_dir."/".$job_id.".sh";

    my $file_test = "if [ -s $sample_ref_bam -a -s $sample_tumor_bam ";
    my $concat_command = "$opt{VCFTOOLS_PATH}/vcf-concat ";
    my $filter_command = "cat $sample_tumor_name\_mutect.vcf | java -Xmx".$opt{MUTECT_MEM}."G -jar $opt{SNPEFF_PATH}/SnpSift.jar filter \"( na FILTER ) | (FILTER = 'PASS')\" > $sample_tumor_name\_mutect_passed.vcf \n";

    foreach my $chr (@chrs) {
        my $output = $sample_tumor_name."_".$chr."_mutect.vcf";
        $file_test .= "-a -s $output ";
        $concat_command .= "$output ";
    }
    $file_test .= "]";
    $concat_command .= "> $sample_tumor_name\_mutect.vcf";

    from_template("MutectCF.sh.tt", "$bash_file", mutect_tmp_dir => $mutect_tmp_dir, file_test => $file_test,
        sample_ref_bam                                           => $sample_ref_bam, sample_tumor_bam =>
        $sample_tumor_bam, sample_tumor_name                     => $sample_tumor_name, concat_command =>
        $concat_command, filter_command                          => $filter_command, mutect_out_dir => $mutect_out_dir,
        log_dir                                                  => $log_dir, runName => $runName, opt => \%opt);

    my $qsub = &qsubJava(\%opt, "MUTECT");
    if (@mutect_jobs) {
        system "$qsub -o $log_dir -e $log_dir -N $job_id -hold_jid ".join(",", @mutect_jobs)." $bash_file";
    } else {
        system "$qsub -o $log_dir -e $log_dir -N $job_id $bash_file";
    }

    return $job_id;
}

############
sub get_chrs_from_dict {
    my $dictFile = shift;
    #my %chrs;
    my @chrs;
    open DICT, $dictFile;
    while(<DICT>) {
        chomp;
        my ($chr, $length) = ($1, $2) if $_ =~ /SN:(\w+)\s*LN:(\d+)/;
        #$chrs{$chr} = $length if $chr;
        push(@chrs, $chr) if $chr;
    }
    close DICT;

    return \@chrs;
}
############

1;
