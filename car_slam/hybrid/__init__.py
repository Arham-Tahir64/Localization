"""Sequential geometry-authority / learned-recovery car SLAM."""

from .pipeline import AppearanceProposal, HybridConfig, SequentialHybridSLAM, run_sequence

__all__ = ["AppearanceProposal", "HybridConfig", "SequentialHybridSLAM", "run_sequence"]
