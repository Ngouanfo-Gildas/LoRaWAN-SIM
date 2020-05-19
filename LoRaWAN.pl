#!/usr/bin/perl -w

###################################################################################
#           Event-based simulator for confirmed LoRaWAN transmissions             #
#                                 v2020.5.18                                      #
#                                                                                 #
# Features:                                                                       #
# -- Multiple half-duplex gateways                                                #
# -- 1% radio duty cycle for the nodes                                            #
# -- 1 or 10% radio duty cycle for the gateways                                   #
# -- Acks with two receive windows (RX1, RX2)                                     #
# -- Non-orthogonal SF transmissions                                              #
# -- Capture effect                                                               #
# -- Path-loss signal attenuation model (uplink+downlink)                         #
# -- Multiple channels                                                            #
# -- Collision handling for both uplink and downlink transmissions                #
# -- Energy consumption calculation (uplink+downlink)                             #
#                                                                                 #
# Assumptions (or work in progress):                                              #
# -- ADR is under development                                                     #
#                                                                                 #
# author: Dr. Dimitrios Zorbas                                                    #
# email: dimzorbas@ieee.org                                                       #
# distributed under GNUv2 General Public Licence                                  #
###################################################################################

use strict;
use POSIX;
use List::Util qw(min max);
use Time::HiRes qw(time);
use Math::Random qw(random_uniform random_exponential);
use Term::ProgressBar 2.00;
use GD::SVG;

die "usage: ./LoRaWAN.pl full_collision_check(0/1) packets_per_hour simulation_time(secs) terrain_file!\n" unless (scalar @ARGV == 4);

# node attributes
my %ncoords = (); # node coordinates
my %nconsumption = (); # consumption
my %nSF = (); # Spreading Factor
my %nretransmisssions = (); # retransmisssions per node
my %surpressed = ();
my %nch = (); # selected channel
my %nreachablegws = (); # reachable gws

# gw attributes
my %gcoords = (); # gw coordinates
my %gunavailability = (); # unavailable gw time due to downlink
my %gdc = (); # gw duty cycle (1% uplink channel is used for RX1, 10% downlink channel is used for RX2)
my %gresponses = (); # acks carried out per gw (not used yet)
my %gdest = (); # contains downlink information [node, sf, RX1/2, channel]

# LoRa PHY and LoRaWAN parameters
my @sensis = ([7,-124,-122,-116], [8,-127,-125,-119], [9,-130,-128,-122], [10,-133,-130,-125], [11,-135,-132,-128], [12,-137,-135,-129]); # sensitivities per SF/BW
my @thresholds = ([6,-16,-18,-19,-19,-20], [-24,6,-20,-22,-22,-22], [-27,-27,6,-23,-25,-25], [-30,-30,-30,6,-26,-28], [-33,-33,-33,-33,6,-29], [-36,-36,-36,-36,-36,6]); # capture effect power thresholds per SF[SF] for non-orthogonal transmissions
my $var = 3.57; # variance
my ($dref, $Ptx, $Lpld0, $gamma) = (40, 14, 95, 2.08); # attenuation model parameters
my $max_retr = 8; # max number of retransmisssions per packet
my $bw = 125000; # channel bandwidth
my $cr = 1; # Coding Rate
my $Ptx_w = 76 * 3.3 / 1000; # mW
my $Prx_w = 46 * 3.3 / 1000;
my $Pidle_w = 30 * 3.3 / 1000; # this is actually the consumption of the microcontroller in idle mode
my @channels = (868100000, 868300000, 868500000, 867100000, 867300000, 867500000, 867700000, 867900000); # TTN channels
my $rx2sf = 12; # SF used for RX2 (LoRaWAN default = SF12, TTN uses SF9)
my $rx2ch = 869525000; # channel used for RX2 (LoRaWAN default = 869.525MHz, TTN uses the same)

# packet specific parameters
my %transmissions = (); # current transmissions
my @fpl = (51, 51, 51, 51, 51, 51); # uplink frame payload per SF (bytes)
my $preamble = 8; # in symbols
my $H = 0; # header 0/1
my $hcrc = 0; # HCRC bytes
my $CRC = 1; # 0/1
my $mhdr = 1; # MAC header (bytes)
my $mic = 4; # MIC bytes
my $fhdr = 7; # frame header without fopts
my $adr = 4; # Fopts option for the ADR (4 Bytes)
my $txdc = 1; # Fopts option for the TX duty cycle (1 Byte)
my $fport_u = 1; # 1B for FPort for uplink
my $fport_d = 0; # 0B for FPort for downlink (commands are included in Fopts, acks have no payload)
my $overhead_u = $mhdr+$mic+$fhdr+$fport_u+$hcrc; # LoRa+LoRaWAN uplink overhead
my $overhead_d = $mhdr+$mic+$fhdr+$fport_d+$hcrc; # LoRa+LoRaWAN downlink overhead
my @pl_u = ($fpl[0]+$overhead_u, $fpl[1]+$overhead_u, $fpl[2]+$overhead_u, $fpl[3]+$overhead_u, $fpl[4]+$overhead_u, $fpl[5]+$overhead_u); # uplink packet payload per SF (bytes)
my %overlaps = (); # handles special packet overlaps 

# simulation parameters
my $full_collision = $ARGV[0]; # take into account non-orthogonal SF transmissions or not
my $period = 3600/$ARGV[1]; # time period between transmissions
my $sim_time = $ARGV[2]; # given simulation time
my $debug = 0; # enable debug mode
my $sim_end = 0;
my ($terrain, $norm_x, $norm_y) = (0, 0, 0); # terrain side (not currenly being used)
my $start_time = time; # just for statistics
my $dropped = 0; # number of dropped packets
my $total_trans = 0; # number of transm. packets
my $total_retrans = 0; # number of re-transm packets
my $acked = 0; # number of acknowledged packets
my $no_rx1 = 0; # no gw was available in RX1
my $no_rx2 = 0; # no gw was available in RX1 or RX2
my $picture = 0; # generate an energy consumption map

my $progress = Term::ProgressBar->new({
	name  => 'Progress',
	count => $sim_time,
	ETA   => 'linear',
});
$progress->max_update_rate(1);
my $next_update = 0;

read_data(); # read terrain file

foreach my $n (keys %ncoords){
	$nSF{$n} = min_sf($n);
	$nretransmisssions{$n} = 0;
}

# first transmission
foreach my $n (keys %ncoords){
	my $start = random_uniform(1, 0, $period); # transmissions are periodic
	my $stop = $start + airtime($nSF{$n});
	# print "# $n will transmit from $start to $stop\n" if ($debug == 1);
	$transmissions{$n} = [$start, $stop];
	$nconsumption{$n} += airtime($nSF{$n}) * $Ptx_w + (airtime($nSF{$n})+1) * $Pidle_w; # +1sec for sensing
	$total_trans += 1;
}

# main loop
while (1){
	print "-------------------------------\n" if ($debug == 1);
	# grab the earliest transmission
	my $sel_sta = 9999999999999;
	my $sel_end = 0;
	my $sel = undef;
	foreach my $n (keys %transmissions){
		my ($sta, $end) = @{$transmissions{$n}};
		if ($sta < $sel_sta){
			$sel_sta = $sta;
			$sel_end = $end;
			$sel = $n;
		}
	}
	$next_update = $progress->update($sel_end);
	if ($sel_sta > $sim_time){
		$next_update = $progress->update($sim_time);
		$progress->update($sim_time);
		last;
	}
	print "# grabbed $sel, transmission at $sel_sta -> $sel_end\n" if ($debug == 1);
	$sim_end = $sel_end;

	if ($sel =~ /^[0-9]/){ # if the packet is an uplink transmission
		
		my $gw_rc = node_col($sel, $sel_sta, $sel_end); # check collisions and compute a list of gws that received the uplink pkt
		my $rwindow = 0;
		my $failed = 0;
		if (scalar @$gw_rc > 0){ # if at least one gateway received the pkt -> successful transmission
			printf "# $sel 's transmission received by %d gateway(s) (channel $nch{$sel})\n", scalar @$gw_rc if ($debug == 1);
			# now we have to find which gateway (if any) can transmit an ack
			# check which gw can send an ack (RX1)
			my $max_p = -9999999999999;
			my $sel_gw = undef;
			my ($ack_sta, $ack_end) = ($sel_end+1, $sel_end+1+airtime($nSF{$sel}, $overhead_d));
			foreach my $g (@$gw_rc){
				my ($gw, $p) = @$g;
				next if ($gdc{$gw}{$nch{$sel}} > ($sel_end+1));
				my $is_available = 1;
				foreach my $gu (@{$gunavailability{$gw}}){
					my ($sta, $end, $ch) = @$gu;
					if ($ch == 0){ # check if the gw is in downlink mode
						if ( (($ack_sta >= $sta) && ($ack_sta <= $end)) || (($ack_end <= $end) && ($ack_end >= $sta)) || (($ack_sta == $sta) && ($ack_end == $end)) ){
							$is_available = 0;
							last;
						}
					}
				}
				next if ($is_available == 0);
				if ($p > $max_p){
					$sel_gw = $gw;
					$max_p = $p;
				}
			}
			if (defined $sel_gw){
				$rwindow = 1;
				print "# gw $sel_gw will transmit an ack to $sel (RX$rwindow) (channel $nch{$sel})\n" if ($debug == 1);
				$gresponses{$sel_gw} += 1;
				push (@{$gunavailability{$sel_gw}}, [$ack_sta, $ack_end, 0]); # "0" denotes downlink transmission
				$gdc{$sel_gw}{$nch{$sel}} = $ack_end+airtime($nSF{$sel}, $overhead_d)*99;
				my $new_name = $sel_gw.$gresponses{$sel_gw}; # e.g. A1
				$transmissions{$new_name} = [$ack_sta, $ack_end];
				$gdest{$sel_gw} = [$sel, $nSF{$sel}, $rwindow, $nch{$sel}];
			}else{
				# check RX2
				$no_rx1 += 1;
				my ($ack_sta, $ack_end) = ($sel_end+2, $sel_end+2+airtime($rx2sf, $overhead_d));
				$max_p = -9999999999999;
				if ($nSF{$sel} < $rx2sf){
					foreach my $g (@{$nreachablegws{$sel}}){
						my ($gw, $p, $ch) = @$g;
						next if ($gdc{$gw}{$rx2ch} > ($sel_end+2));
						my $is_available = 1;
						foreach my $gu (@{$gunavailability{$gw}}){
							my ($sta, $end, $ch) = @$gu;
							if ($ch == 0){
								if ( (($ack_sta >= $sta) && ($ack_sta <= $end)) || (($ack_end <= $end) && ($ack_end >= $sta)) || (($ack_sta == $sta) && ($ack_end == $end)) ){
									$is_available = 0;
									last;
								}
							}
						}
						next if ($is_available == 0);
						if ($p > $max_p){
							$sel_gw = $gw;
							$max_p = $p;
						}
					}
				}else{
					foreach my $g (@$gw_rc){
						my ($gw, $p) = @$g;
						next if ($gdc{$gw}{$rx2ch} > ($sel_end+2));
						my $is_available = 1;
						foreach my $gu (@{$gunavailability{$gw}}){
							my ($sta, $end, $ch) = @$gu;
							if ($ch == 0){
								if ( (($ack_sta >= $sta) && ($ack_sta <= $end)) || (($ack_end <= $end) && ($ack_end >= $sta)) || (($ack_sta == $sta) && ($ack_end == $end)) ){
									$is_available = 0;
									last;
								}
							}
						}
						next if ($is_available == 0);
						if ($p > $max_p){
							$sel_gw = $gw;
							$max_p = $p;
						}
					}
				}
				if (defined $sel_gw){
					$rwindow = 2;
					print "# gw $sel_gw will transmit an ack to $sel (RX$rwindow) (channel $rx2ch)\n" if ($debug == 1);
					$gresponses{$sel_gw} += 1;
					push (@{$gunavailability{$sel_gw}}, [$ack_sta, $ack_end, 0]);
					$gdc{$sel_gw}{$rx2ch} = $ack_end+airtime($rx2sf, $overhead_d)*90;
					my $new_name = $sel_gw.$gresponses{$sel_gw};
					$transmissions{$new_name} = [$ack_sta, $ack_end];
					$gdest{$sel_gw} = [$sel, $rx2sf, $rwindow, $rx2ch];
				}else{
					$no_rx2 += 1;
					print "# no gateway is available\n" if ($debug == 1);
					$failed = 1;
				}
			}
		}else{ # non-successful transmission
			$failed = 1;
		}
		delete $transmissions{$sel}; # delete the old transmission
		if ($failed == 1){
			if ($nretransmisssions{$sel} < $max_retr){
				$nretransmisssions{$sel} += 1;
			}else{
				$dropped += 1;
				$nretransmisssions{$sel} = 0;
				print "# $sel 's packet lost!\n" if ($debug == 1);
			}
			# the node stays on only for the duration of the preamble for both windows
			$nconsumption{$sel} += $preamble*(2**$nSF{$sel})/$bw * ($Prx_w + $Pidle_w);
			$nconsumption{$sel} += $preamble*(2**$rx2sf)/$bw * ($Prx_w + $Pidle_w);
			# plan the next transmission 
			my $at = airtime($nSF{$sel});
			$sel_sta = $sel_end + $rwindow + $period + rand(1);
			my $next_allowed = $sel_end + 99*$at;
			if ($sel_sta < $next_allowed){
				print "# warning! transmission will be postponed due to duty cycle restrictions!\n" if ($debug == 1);
				$sel_sta = $next_allowed;
			}
			$sel_end = $sel_sta+$at;
			$transmissions{$sel} = [$sel_sta, $sel_end];
			$total_trans += 1 if ($sel_sta+5 < $sim_time); # do not count transmissions that exceed the simulation time
			$total_retrans += 1 if ($sel_sta+5 < $sim_time);
			print "# $sel, new transmission at $sel_sta -> $sel_end\n" if ($debug == 1);
			$nconsumption{$sel} += $at * $Ptx_w + (airtime($nSF{$sel})+1) * $Pidle_w if ($sel_sta+5 < $sim_time);
		}else{
			# this case will be handled during the ack transmission
		}
		foreach my $g (keys %gcoords){
			$surpressed{$sel}{$g} = 0;
		}
		
		
	}else{ # if the packet is a gw transmission
		
		
		delete $transmissions{$sel}; # delete the old transmission
		$sel =~ s/[0-9].*//; # keep only the letter(s)
		# reduce gunavailability population
		my @indices = ();
		my $index = 0;
		foreach my $tuple (@{$gunavailability{$sel}}){
			my ($sta, $end, $ch) = @$tuple;
			push (@indices, $index) if ($end < $sel_sta);
		}
		for (sort {$b<=>$a} @indices){
			splice @{$gunavailability{$sel}}, $_, 1;
		}
		
		# check if it collides with other transmissions
		my $failed = 0;
		my ($dest, $sf, $rwindow, $ch) = @{$gdest{$sel}};
		# first check if the transmission can reach the node
		my $G = rand(1);
		my $d = distance($gcoords{$sel}[0], $ncoords{$dest}[0], $gcoords{$sel}[1], $ncoords{$dest}[1]);
		my $prx = $Ptx - ($Lpld0 + 10*$gamma * log10($d/$dref) + $G*$var);
		if ($prx < $sensis[$sf-7][bwconv($bw)]){
			print "# ack didn't reach node $dest\n" if ($debug == 1);
			$failed = 1;
		}
		foreach my $n (keys %transmissions){
			my ($sta, $end) = @{$transmissions{$n}};
			my $nn = $n;
			$n =~ s/[0-9].*// if ($n =~ /^[A-Z]/);
			next if (($n eq $sel) || ($sta > $sel_end) || ($end < $sel_sta)); # skip non-overlapping transmissions
			if ($n =~ /^[0-9]/){ # skip transmissions on different channels
				next if ($nch{$dest} != $nch{$n});
			}else{
				next if ($gdest{$n}[3] != $ch);
			}
			
			# time overlap
			if ( (($sel_sta >= $sta) && ($sel_sta <= $end)) || (($sel_end <= $end) && ($sel_end >= $sta)) || (($sel_sta == $sta) && ($sel_end == $end)) ){
				my $already_there = 0;
				my $G_ = rand(1);
				my $sf_ = 0;
				if ($n =~ /^[0-9]/){
					$sf_ = $nSF{$n};
				}else{
					$sf_ = $gdest{$n}[1];
				}
				foreach my $ng (@{$overlaps{$sel}}){
					my ($n_, $G_, $sf_) = @$ng;
					if (($n_ eq $n) || ($n_ eq $nn)){
						$already_there = 1;
					}
				}
				if ($already_there == 0){
					push(@{$overlaps{$sel}}, [$n, $G_, $sf_]); # put in here all overlapping transmissions
				}
				push(@{$overlaps{$nn}}, [$sel, $G, $sf]); # check future possible collisions with those transmissions
			}
		}
		foreach my $ng (@{$overlaps{$sel}}){
			my ($n, $G_, $sf_) = @$ng;
			my $overlap = 1;
			# SF
			if ($sf_ == $sf){
				$overlap += 2;
			}
			# power 
			my $d_ = 0;
			if ($n =~ /^[0-9]/){
				$d_ = distance($ncoords{$dest}[0], $ncoords{$n}[0], $ncoords{$dest}[1], $ncoords{$n}[1]);
			}else{
				$d_ = distance($ncoords{$dest}[0], $gcoords{$n}[0], $ncoords{$dest}[1], $gcoords{$n}[1]);
			}
			my $prx_ = $Ptx - ($Lpld0 + 10*$gamma * log10($d_/$dref) + $G_*$var);
			if ($overlap == 3){
				if ((abs($prx - $prx_) <= $thresholds[$sf-7][$sf_-7]) ){ # both collide
					$failed = 1;
					print "# ack collided together with $n at node $sel\n" if ($debug == 1);
				}
				if (($prx_ - $prx) > $thresholds[$sf-7][$sf_-7]){ # n suppressed sel
					$failed = 1;
					print "# ack surpressed by $n at node $dest\n" if ($debug == 1);
				}
				if (($prx - $prx_) > $thresholds[$sf_-7][$sf-7]){ # sel suppressed n
					print "# $n surpressed by $sel at node $dest\n" if ($debug == 1);
				}
			}
			if (($overlap == 1) && ($full_collision == 1)){ # non-orthogonality
				if (($prx - $prx_) > $thresholds[$sf-7][$sf_-7]){
					if (($prx_ - $prx) <= $thresholds[$sf_-7][$sf-7]){
						print "# $n surpressed by $sel at node $dest\n" if ($debug == 1);
					}
				}else{
					if (($prx_ - $prx) > $thresholds[$sf_-7][$sf-7]){
						$failed = 1;
						print "# ack surpressed by $n at node $dest\n" if ($debug == 1);
					}else{
						$failed = 1;
						print "# ack collided together with $n at node $dest\n" if ($debug == 1);
					}
				}
			}
		}
		if ($failed == 0){ 
			print "# ack successfully received, $dest 's transmission has been acked\n" if ($debug == 1);
			$nretransmisssions{$dest} = 0;
			$acked += 1;
			$nconsumption{$dest} += airtime($sf, $overhead_d) * ($Prx_w + $Pidle_w);
			if ($rwindow == 2){ # also count the RX1 window
				$nconsumption{$dest} += $preamble*(2**$nSF{$dest})/$bw * ($Prx_w + $Pidle_w);
			}
		}else{ # ack was not received
			if ($nretransmisssions{$dest} < $max_retr){
				$nretransmisssions{$dest} += 1;
			}else{
				$dropped += 1;
				$nretransmisssions{$dest} = 0;
				print "# $dest 's packet lost (no ack received)!\n" if ($debug == 1);
			}
			$nconsumption{$dest} += $preamble*(2**$nSF{$dest})/$bw * ($Prx_w + $Pidle_w);
			$nconsumption{$dest} += $preamble*(2**$rx2sf)/$bw * ($Prx_w + $Pidle_w);
		}
		@{$overlaps{$sel}} = ();
		# plan next transmission
		my $at = airtime($nSF{$dest});
		my $new_start = $sel_sta - $rwindow + $period + rand(1);
		my $next_allowed = $sel_sta - $rwindow + 99*$at;
		if ($new_start < $next_allowed){
			print "# warning! transmission will be postponed due to duty cycle restrictions!\n" if ($debug == 1);
			$new_start = $next_allowed;
		}
		my $new_end = $new_start + $at;
		$transmissions{$dest} = [$new_start, $new_end];
		$total_trans += 1 if ($new_start+5 < $sim_time); # do not count transmissions that exceed the simulation time
		$total_retrans += 1 if (($failed == 1) && ($new_start+5 < $sim_time)); 
		print "# $dest, new transmission at $new_start -> $new_end\n" if ($debug == 1);
		$nconsumption{$dest} += $at * $Ptx_w + (airtime($nSF{$dest})+1) * $Pidle_w if ($new_start+5 < $sim_time);
	}
}
# print "---------------------\n";

my $avg_cons = 0;
my $min_cons = 99999999999999999999;
my $max_cons = 0;
foreach my $n (keys %ncoords){
	$avg_cons += $nconsumption{$n};
	if ($nconsumption{$n} < $min_cons){
		$min_cons = $nconsumption{$n};
	}
	if ($nconsumption{$n} > $max_cons){
		$max_cons = $nconsumption{$n};
	}
}
my $finish_time = time;
printf "Simulation time = %.3f secs\n", $sim_end;
printf "Avg node consumption = %.5f mJ\n", $avg_cons/(scalar keys %ncoords);
printf "Min node consumption = %.5f mJ\n", $min_cons;
printf "Max node consumption = %.5f mJ\n", $max_cons;
print "Total number of transmissions = $total_trans\n";
print "Total number of re-transmissions = $total_retrans\n";
printf "Total number of unique transmissions = %d\n", $total_trans-$total_retrans;
print "Total packets acknowledged = $acked\n";
print "Total packets dropped = $dropped\n";
printf "Packet Delivery Ratio 1 = %.5f\n", $acked/($total_trans-$total_retrans); # ACKed PDR
printf "Packet Delivery Ratio 2 = %.5f\n", ($total_trans-$total_retrans)/$total_trans; # Global PDR
print "No GW available in RX1 = $no_rx1 times\n";
print "No GW available in RX1 or RX2 = $no_rx2 times\n";
printf "Script execution time = %.4f secs\n", $finish_time - $start_time;
print "-----\n";
foreach my $g (sort keys %gcoords){
	print "GW $g sent out $gresponses{$g} acks\n";
}
generate_picture() if ($picture == 1);


sub node_col{
	my ($sel, $sel_sta, $sel_end) = @_;
	# check for collisions with other transmissions (time, SF, power) per gw
	my @gw_rc = ();
	foreach my $gw (keys %gcoords){
		next if ($surpressed{$sel}{$gw} == 1);
		my $d = distance($gcoords{$gw}[0], $ncoords{$sel}[0], $gcoords{$gw}[1], $ncoords{$sel}[1]);
		my $G = rand(1);
		my $prx = $Ptx - ($Lpld0 + 10*$gamma * log10($d/$dref) + $G*$var);
		if ($prx < $sensis[$nSF{$sel}-7][bwconv($bw)]){
			$surpressed{$sel}{$gw} = 1;
			print "# packet didn't reach gw $gw\n" if ($debug == 1);
			next;
		}
		my $is_available = 1;
		foreach my $gu (@{$gunavailability{$gw}}){
			my ($sta, $end, $ch) = @$gu;
			if ( (($sel_sta >= $sta) && ($sel_sta <= $end)) || (($sel_end <= $end) && ($sel_end >= $sta)) || (($sel_sta == $sta) && ($sel_end == $end)) ){
				if ($nch{$sel} == $ch){
					$is_available = 0;
					last;
				}
			}
		}
		if ($is_available == 0){
			$surpressed{$sel}{$gw} = 1;
			print "# gw not available for uplink (channel $nch{$sel})\n" if ($debug == 1);
			next;
		}
		foreach my $n (keys %transmissions){
			if ($n =~ /^[0-9]/){ # node transmission
				my ($sta, $end) = @{$transmissions{$n}};
				next if (($n == $sel) || ($sta > $sel_end) || ($end < $sel_sta) || ($nch{$sel} != $nch{$n}));
				my $overlap = 0;
				# time overlap
				if ( (($sel_sta >= $sta) && ($sel_sta <= $end)) || (($sel_end <= $end) && ($sel_end >= $sta)) || (($sel_sta == $sta) && ($sel_end == $end)) ){
					$overlap += 1;
				}
				# SF
				if ($nSF{$n} == $nSF{$sel}){
					$overlap += 2;
				}
				# power 
				my $d_ = distance($gcoords{$gw}[0], $ncoords{$n}[0], $gcoords{$gw}[1], $ncoords{$n}[1]);
				my $prx_ = $Ptx - ($Lpld0 + 10*$gamma * log10($d_/$dref) + rand(1)*$var);
				if ($overlap == 3){
					if ((abs($prx - $prx_) <= $thresholds[$nSF{$sel}-7][$nSF{$n}-7]) ){ # both collide
						$surpressed{$sel}{$gw} = 1;
						$surpressed{$n}{$gw} = 1;
						print "# $sel collided together with $n at gateway $gw\n" if ($debug == 1);
					}
					if (($prx_ - $prx) > $thresholds[$nSF{$sel}-7][$nSF{$n}-7]){ # n suppressed sel
						$surpressed{$sel}{$gw} = 1;
						print "# $sel surpressed by $n at gateway $gw\n" if ($debug == 1);
					}
					if (($prx - $prx_) > $thresholds[$nSF{$n}-7][$nSF{$sel}-7]){ # sel suppressed n
						$surpressed{$n}{$gw} = 1;
						print "# $n surpressed by $sel at gateway $gw\n" if ($debug == 1);
					}
				}
				if (($overlap == 1) && ($full_collision == 1)){ # non-orthogonality
					if (($prx - $prx_) > $thresholds[$nSF{$sel}-7][$nSF{$n}-7]){
						if (($prx_ - $prx) <= $thresholds[$nSF{$n}-7][$nSF{$sel}-7]){
							$surpressed{$n}{$gw} = 1;
							print "# $n surpressed by $sel\n" if ($debug == 1);
						}
					}else{
						if (($prx_ - $prx) > $thresholds[$nSF{$n}-7][$nSF{$sel}-7]){
							$surpressed{$sel}{$gw} = 1;
							print "# $sel surpressed by $n\n" if ($debug == 1);
						}else{
							$surpressed{$sel}{$gw} = 1;
							$surpressed{$n}{$gw} = 1;
							print "# $sel collided together with $n\n" if ($debug == 1);
						}
					}
				}
			}else{ # n is a gw in this case
				my ($sta, $end) = @{$transmissions{$n}};					
				my $nn = $n;
				$n =~ s/[0-9].*//; # keep only the letter(s)
				next if (($nn eq $gw) || ($sta > $sel_end) || ($end < $sel_sta) || ($gdest{$n}[3] != $nch{$sel}));
				# time overlap
				if ( (($sel_sta >= $sta) && ($sel_sta <= $end)) || (($sel_end <= $end) && ($sel_end >= $sta)) || (($sel_sta == $sta) && ($sel_end == $end)) ){
					my $already_there = 0;
					my $G_ = rand(1);
					my $sf_ = 0;
					if ($n =~ /^[0-9]/){
						$sf_ = $nSF{$n};
					}else{
						$sf_ = $gdest{$n}[1];
					}
					foreach my $ng (@{$overlaps{$sel}}){
						my ($n_, $G_, $sf_) = @$ng;
						if ($n_ eq $n){
							$already_there = 1;
						}
					}
					if ($already_there == 0){
						push(@{$overlaps{$sel}}, [$n, $G_, $sf_]); # put in here all overlapping transmissions
					}
					push(@{$overlaps{$nn}}, [$sel, $G, $nSF{$sel}]); # check future possible collisions with those transmissions
				}
				foreach my $ng (@{$overlaps{$sel}}){
					my ($n, $G_, $sf_) = @$ng;
					my $overlap = 1;
					# SF
					if ($sf_ == $nSF{$sel}){
						$overlap += 2;
					}
					# power 
					my $d_ = distance($gcoords{$gw}[0], $gcoords{$n}[0], $gcoords{$gw}[1], $gcoords{$n}[1]);
					my $prx_ = $Ptx - ($Lpld0 + 10*$gamma * log10($d_/$dref) + $G_*$var);
					if ($overlap == 3){
						if ((abs($prx - $prx_) <= $thresholds[$nSF{$sel}-7][$sf_-7]) ){ # both collide
							$surpressed{$sel}{$gw} = 1;
							print "# $sel collided together with $n at gateway $gw\n" if ($debug == 1);
						}
						if (($prx_ - $prx) > $thresholds[$nSF{$sel}-7][$sf_-7]){ # n suppressed sel
							$surpressed{$sel}{$gw} = 1;
							print "# $sel surpressed by $n at gateway $gw\n" if ($debug == 1);
						}
						if (($prx - $prx_) > $thresholds[$sf_-7][$nSF{$sel}-7]){ # sel suppressed n
							print "# $n surpressed by $sel at gateway $gw\n" if ($debug == 1);
						}
					}
					if (($overlap == 1) && ($full_collision == 1)){ # non-orthogonality
						if (($prx - $prx_) > $thresholds[$nSF{$sel}-7][$sf_-7]){
							if (($prx_ - $prx) <= $thresholds[$sf_-7][$nSF{$sel}-7]){
								print "# $n surpressed by $sel\n" if ($debug == 1);
							}
						}else{
							if (($prx_ - $prx) > $thresholds[$sf_-7][$nSF{$sel}-7]){
								$surpressed{$sel}{$gw} = 1;
								print "# $sel surpressed by $n\n" if ($debug == 1);
							}else{
								$surpressed{$sel}{$gw} = 1;
								print "# $sel collided together with $n\n" if ($debug == 1);
							}
						}
					}
				}
			}
		}
		if ($surpressed{$sel}{$gw} == 0){
			push (@gw_rc, [$gw, $prx]);
			# set the gw unavailable (exclude preamble)
			my $pr_time = 2**$nSF{$sel}/$bw;
			push(@{$gunavailability{$gw}}, [$sel_sta+$pr_time, $sel_end, $nch{$sel}]);
		}
	}
	@{$overlaps{$sel}} = ();
	return (\@gw_rc);
}

sub min_sf{
	my $n = shift;
	my $G = rand(1);
	my ($dref, $Ptx, $Lpld0, $Xs, $gamma) = (40, 7, 95, $var*$G, 2.08);
	my $sf = 0;
	my $bwi = bwconv($bw);
	foreach my $gw (keys %gcoords){
		my $d0 = distance($gcoords{$gw}[0], $ncoords{$n}[0], $gcoords{$gw}[1], $ncoords{$n}[1]);
		for (my $f=7; $f<=12; $f+=1){
			my $S = $sensis[$f-7][$bwi];
			my $Prx = $Ptx - ($Lpld0 + 10*$gamma * log10($d0/$dref) + $Xs);
			if (($Prx - 10) > $S){ # 10dBm tolerance
				$sf = $f;
				$f = 13;
				last;
			}
		}
	}
	# check which gateways can reach the node with rx2sf
	foreach my $gw (keys %gcoords){
		my $d0 = distance($gcoords{$gw}[0], $ncoords{$n}[0], $gcoords{$gw}[1], $ncoords{$n}[1]);
		my $S = $sensis[$rx2sf-7][$bwi];
		my $Prx = $Ptx - ($Lpld0 + 10*$gamma * log10($d0/$dref) + $Xs);
		if (($Prx - 10) > $S){ # 10dBm tolerance
			push(@{$nreachablegws{$n}}, [$gw, $Prx]);
		}
	}
	if ($sf == 0){
		print "node $n unreachable!\n";
		print "terrain too large?\n";
		exit;
	}
	# print "# $n can reach a gw with SF$sf\n" if ($debug == 1);
	return $sf;
}

# a modified version of LoRaSim (https://www.lancaster.ac.uk/scc/sites/lora/lorasim.html)
sub airtime{
	my $sf = shift;
	my $DE = 0;      # low data rate optimization enabled (=1) or not (=0)
	my $payload = shift;
	$payload = $pl_u[$sf-7] if (!defined $payload);
	if (($bw == 125000) && (($sf == 11) || ($sf == 12))){
		# low data rate optimization mandated for BW125 with SF11 and SF12
		$DE = 1;
	}
	my $Tsym = (2**$sf)/$bw;
	my $Tpream = ($preamble + 4.25)*$Tsym;
	my $payloadSymbNB = 8 + max( ceil((8.0*$payload-4.0*$sf+28+16*$CRC-20*$H)/(4.0*($sf-2*$DE)))*($cr+4), 0 );
	my $Tpayload = $payloadSymbNB * $Tsym;
	return ($Tpream + $Tpayload);
}

sub bwconv{
	my $bwi = 0;
	if ($bw == 125000){
		$bwi = 1;
	}elsif ($bw == 250000){
		$bwi = 2;
	}elsif ($bw == 500000){
		$bwi = 3;
	}
	return $bwi;
}

sub read_data{
	my $terrain_file = $ARGV[3];
	open(FH, "<$terrain_file") or die "Error: could not open terrain file $terrain_file\n";
	my @nodes = ();
	my @gateways = ();
	while(<FH>){
		chomp;
		if (/^# stats: (.*)/){
			my $stats_line = $1;
			if ($stats_line =~ /terrain=([0-9]+\.[0-9]+)m\^2/){
				$terrain = $1;
			}
			$norm_x = sqrt($terrain);
			$norm_y = sqrt($terrain);
		} elsif (/^# node coords: (.*)/){
			my $sensor_coord = $1;
			my @coords = split(/\] /, $sensor_coord);
			@nodes = map { /([0-9]+) \[([0-9]+\.[0-9]+) ([0-9]+\.[0-9]+)/; [$1, $2, $3]; } @coords;
		} elsif (/^# gateway coords: (.*)/){
			my $gw_coord = $1;
			my @coords = split(/\] /, $gw_coord);
			@gateways = map { /([A-Z]+) \[([0-9]+\.[0-9]+) ([0-9]+\.[0-9]+)/; [$1, $2, $3]; } @coords;
		}
	}
	close(FH);
	
	foreach my $node (@nodes){
		my ($n, $x, $y) = @$node;
		$ncoords{$n} = [$x, $y];
		$nch{$n} = $channels[rand @channels];
		# print "$n picked channel $nch{$n}\n" if ($debug == 1);
		@{$overlaps{$n}} = ();
	}
	foreach my $gw (@gateways){
		my ($g, $x, $y) = @$gw;
		$gcoords{$g} = [$x, $y];
		@{$gunavailability{$g}} = ();
		foreach my $ch (@channels){
			$gdc{$g}{$ch} = 0;
		}
		$gdc{$g}{$rx2ch} = 0;
		foreach my $n (keys %ncoords){
			$surpressed{$n}{$g} = 0;
		}
		@{$overlaps{$g}} = ();
	}
}

sub distance {
	my ($x1, $x2, $y1, $y2) = @_;
	return sqrt( (($x1-$x2)*($x1-$x2))+(($y1-$y2)*($y1-$y2)) );
}

sub distance3d {
	my ($x1, $x2, $y1, $y2, $z1, $z2) = @_;
	return sqrt( (($x1-$x2)*($x1-$x2))+(($y1-$y2)*($y1-$y2))+(($z1-$z2)*($z1-$z2)) );
}

sub generate_picture{
	my ($display_x, $display_y) = (800, 800); # 800x800 pixel display pane
	my $im = new GD::SVG::Image($display_x, $display_y);
	my $blue = $im->colorAllocate(0,0,255);
	my $black = $im->colorAllocate(0,0,0);
	my $red = $im->colorAllocate(255,0,0);
	
	foreach my $n (keys %ncoords){
		my ($x, $y) = @{$ncoords{$n}};
		($x, $y) = (int(($x * $display_x)/$norm_x), int(($y * $display_y)/$norm_y));
		my $color = $im->colorAllocate(255*$nconsumption{$n}/$max_cons,0,0);
		$im->filledArc($x,$y,20,20,0,360,$color);
	}
	
	foreach my $g (keys %gcoords){
		my ($x, $y) = @{$gcoords{$g}};
		($x, $y) = (int(($x * $display_x)/$norm_x), int(($y * $display_y)/$norm_y));
		$im->rectangle($x-5, $y-5, $x+5, $y+5, $red);
		$im->string(gdGiantFont,$x-2,$y-20,$g,$blue);
	}
	my $output_file = $ARGV[3]."-img.svg";
	open(FILEOUT, ">$output_file") or die "could not open file $output_file for writing!";
	binmode FILEOUT;
	print FILEOUT $im->svg;
	close FILEOUT;
}
