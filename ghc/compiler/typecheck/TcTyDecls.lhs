%
% (c) The AQUA Project, Glasgow University, 1996-1998
%
\section[TcTyDecls]{Typecheck type declarations}

\begin{code}
module TcTyDecls (
	tcTyDecl, kcTyDecl, 
	tcConDecl,
	mkDataBinds
    ) where

#include "HsVersions.h"

import HsSyn		( MonoBinds(..), 
			  TyClDecl(..), ConDecl(..), ConDetails(..), BangType(..),
			  andMonoBindList
			)
import RnHsSyn		( RenamedTyClDecl, RenamedConDecl )
import TcHsSyn		( TcMonoBinds )
import BasicTypes	( RecFlag(..), NewOrData(..), StrictnessMark(..) )

import TcMonoType	( tcExtendTopTyVarScope, tcExtendTyVarScope, 
			  tcHsTypeKind, tcHsType, tcHsTopType, tcHsTopBoxedType,
			  tcContext
			)
import TcType		( zonkTcTyVarToTyVar, zonkTcThetaType )
import TcEnv		( tcLookupTy, TcTyThing(..) )
import TcMonad
import TcUnify		( unifyKind )

import Class		( Class )
import DataCon		( DataCon, dataConSig, mkDataCon, isNullaryDataCon,
			  dataConFieldLabels, dataConId
			)
import MkId		( mkDataConId, mkRecordSelId, mkNewTySelId )
import Id		( getIdUnfolding )
import CoreUnfold	( getUnfoldingTemplate )
import FieldLabel
import Var		( Id, TyVar )
import Name		( isLocallyDefined, OccName, NamedThing(..) )
import Outputable
import TyCon		( TyCon, mkSynTyCon, mkAlgTyCon, isAlgTyCon, 
			  isSynTyCon, tyConDataCons, isNewTyCon
			)
import Type		( getTyVar, tyVarsOfTypes,
			  mkTyConApp, mkTyVarTys, mkForAllTys, mkFunTy,
			  mkTyVarTy,
			  mkArrowKind, mkArrowKinds, boxedTypeKind,
			  isUnboxedType, Type, ThetaType
			)
import Var		( tyVarKind )
import VarSet		( intersectVarSet, isEmptyVarSet )
import Util		( equivClasses )
\end{code}

%************************************************************************
%*									*
\subsection{Kind checking}
%*									*
%************************************************************************

\begin{code}
kcTyDecl :: RenamedTyClDecl -> TcM s ()

kcTyDecl (TySynonym name tyvar_names rhs src_loc)
  = tcLookupTy name				`thenNF_Tc` \ (kind, _, _) ->
    tcExtendTopTyVarScope kind tyvar_names	$ \ _ result_kind ->
    tcHsTypeKind rhs				`thenTc` \ (rhs_kind, _) ->
    unifyKind result_kind rhs_kind

kcTyDecl (TyData _ context tycon_name tyvar_names con_decls _ _ src_loc)
  = tcLookupTy tycon_name			`thenNF_Tc` \ (kind, _, _) ->
    tcExtendTopTyVarScope kind tyvar_names	$ \ result_kind _ ->
    tcContext context				`thenTc_` 
    mapTc kcConDecl con_decls			`thenTc_`
    returnTc ()

kcConDecl (ConDecl _ ex_tvs ex_ctxt details loc)
  = tcAddSrcLoc loc			(
    tcExtendTyVarScope ex_tvs		( \ tyvars -> 
    tcContext ex_ctxt			`thenTc_`
    kc_con details			`thenTc_`
    returnTc ()
    ))
  where
    kc_con (VanillaCon btys)    = mapTc kc_bty btys		`thenTc_` returnTc ()
    kc_con (InfixCon bty1 bty2) = mapTc kc_bty [bty1,bty2]	`thenTc_` returnTc ()
    kc_con (NewCon ty _)        = tcHsType ty			`thenTc_` returnTc ()
    kc_con (RecCon flds)        = mapTc kc_field flds		`thenTc_` returnTc ()

    kc_bty (Banged ty)   = tcHsType ty
    kc_bty (Unbanged ty) = tcHsType ty

    kc_field (_, bty)    = kc_bty bty
\end{code}


%************************************************************************
%*									*
\subsection{Type checking}
%*									*
%************************************************************************

\begin{code}
tcTyDecl :: RecFlag -> RenamedTyClDecl -> TcM s TyCon

tcTyDecl is_rec (TySynonym tycon_name tyvar_names rhs src_loc)
  = tcLookupTy tycon_name				`thenNF_Tc` \ (tycon_kind, Just arity, _) ->
    tcExtendTopTyVarScope tycon_kind tyvar_names	$ \ tyvars _ ->
    tcHsTopType rhs					`thenTc` \ rhs_ty ->
    let
	-- Construct the tycon
	tycon = mkSynTyCon tycon_name tycon_kind arity tyvars rhs_ty
    in
    returnTc tycon


tcTyDecl is_rec (TyData data_or_new context tycon_name tyvar_names con_decls derivings pragmas src_loc)
  = 	-- Lookup the pieces
    tcLookupTy tycon_name				`thenNF_Tc` \ (tycon_kind, _, ATyCon rec_tycon) ->
    tcExtendTopTyVarScope tycon_kind tyvar_names	$ \ tyvars _ ->

	-- Typecheck the pieces
    tcContext context					`thenTc` \ ctxt ->
    mapTc (tcConDecl rec_tycon tyvars ctxt) con_decls	`thenTc` \ data_cons ->
    tc_derivs derivings					`thenTc` \ derived_classes ->

    let
	-- Construct the tycon
	real_data_or_new = case data_or_new of
				NewType -> NewType
				DataType | all isNullaryDataCon data_cons -> EnumType
					 | otherwise			  -> DataType

	tycon = mkAlgTyCon tycon_name tycon_kind tyvars ctxt
			   data_cons
			   derived_classes
			   Nothing		-- Not a dictionary
			   real_data_or_new is_rec
    in
    returnTc tycon
  where
	tc_derivs Nothing   = returnTc []
	tc_derivs (Just ds) = mapTc tc_deriv ds

	tc_deriv name = tcLookupTy name `thenTc` \ (_, _, AClass clas) ->
			returnTc clas
\end{code}


%************************************************************************
%*									*
\subsection{Type check constructors}
%*									*
%************************************************************************

\begin{code}
tcConDecl :: TyCon -> [TyVar] -> ThetaType -> RenamedConDecl -> TcM s DataCon

tcConDecl tycon tyvars ctxt (ConDecl name ex_tvs ex_ctxt details src_loc)
  = tcAddSrcLoc src_loc			$
    tcExtendTyVarScope ex_tvs		$ \ ex_tyvars -> 
    tcContext ex_ctxt			`thenTc` \ ex_theta ->
    tc_con_decl_help tycon tyvars ctxt name ex_tyvars ex_theta details

tc_con_decl_help tycon tyvars ctxt name ex_tyvars ex_theta details
  = case details of
	VanillaCon btys    -> tc_datacon btys
	InfixCon bty1 bty2 -> tc_datacon [bty1,bty2]
	NewCon ty mb_f	   -> tc_newcon ty mb_f
	RecCon fields	   -> tc_rec_con fields
  where
    tc_datacon btys
      = let
	    arg_stricts = map get_strictness btys
	    tys	        = map get_pty btys
        in
	mapTc tcHsTopType tys `thenTc` \ arg_tys ->
	mk_data_con arg_stricts arg_tys []

    tc_newcon ty mb_f
      = tcHsTopBoxedType ty	`thenTc` \ arg_ty ->
	    -- can't allow an unboxed type here, because we're effectively
	    -- going to remove the constructor while coercing it to a boxed type.
	let
	  field_label =
	    case mb_f of
	      Nothing -> []
	      Just f  -> [mkFieldLabel (getName f) arg_ty (head allFieldLabelTags)]
        in	      
	mk_data_con [NotMarkedStrict] [arg_ty] field_label

    tc_rec_con fields
      = checkTc (null ex_tyvars) (exRecConErr name)	    `thenTc_`
	mapTc tc_field fields	`thenTc` \ field_label_infos_s ->
	let
	    field_label_infos = concat field_label_infos_s
	    arg_stricts       = [strict | (_, _, strict) <- field_label_infos]
	    arg_tys	      = [ty     | (_, ty, _)     <- field_label_infos]

	    field_labels      = [ mkFieldLabel (getName name) ty tag 
			      | ((name, ty, _), tag) <- field_label_infos `zip` allFieldLabelTags ]
	in
	mk_data_con arg_stricts arg_tys field_labels

    tc_field (field_label_names, bty)
      = tcHsTopType (get_pty bty)	`thenTc` \ field_ty ->
	returnTc [(name, field_ty, get_strictness bty) | name <- field_label_names]

    mk_data_con arg_stricts arg_tys fields
      = 	-- Now we've checked all the field types we must
		-- zonk the existential tyvars to finish the kind
		-- inference on their kinds, and commit them to being
		-- immutable type variables.  (The top-level tyvars are
		-- already fixed, by the preceding kind-inference pass.)
	mapNF_Tc zonkTcTyVarToTyVar ex_tyvars	`thenNF_Tc` \ ex_tyvars' ->
	zonkTcThetaType	ex_theta		`thenNF_Tc` \ ex_theta' ->
	let
	   data_con = mkDataCon name arg_stricts fields
		      	   tyvars (thinContext arg_tys ctxt)
			   ex_tyvars' ex_theta'
		      	   arg_tys
		      	   tycon data_con_id
	   data_con_id = mkDataConId data_con
	in
	returnNF_Tc data_con

-- The context for a data constructor should be limited to
-- the type variables mentioned in the arg_tys
thinContext arg_tys ctxt
  = filter in_arg_tys ctxt
  where
      arg_tyvars = tyVarsOfTypes arg_tys
      in_arg_tys (clas,tys) = not $ isEmptyVarSet $ 
			      tyVarsOfTypes tys `intersectVarSet` arg_tyvars
  
get_strictness (Banged   _) = MarkedStrict
get_strictness (Unbanged _) = NotMarkedStrict

get_pty (Banged ty)   = ty
get_pty (Unbanged ty) = ty
\end{code}



%************************************************************************
%*									*
\subsection{Generating constructor/selector bindings for data declarations}
%*									*
%************************************************************************

\begin{code}
mkDataBinds :: [TyCon] -> TcM s ([Id], TcMonoBinds)
mkDataBinds [] = returnTc ([], EmptyMonoBinds)
mkDataBinds (tycon : tycons) 
  | isSynTyCon tycon = mkDataBinds tycons
  | otherwise	     = mkDataBinds_one tycon	`thenTc` \ (ids1, b1) ->
		       mkDataBinds tycons	`thenTc` \ (ids2, b2) ->
		       returnTc (ids1++ids2, b1 `AndMonoBinds` b2)

mkDataBinds_one tycon
  = mapTc (mkRecordSelector tycon) groups	`thenTc` \ sel_ids ->
    let
	data_ids = map dataConId data_cons ++ sel_ids

	-- For the locally-defined things
	-- we need to turn the unfoldings inside the Ids into bindings,
	binds = [ CoreMonoBind data_id (getUnfoldingTemplate (getIdUnfolding data_id))
		| data_id <- data_ids, isLocallyDefined data_id
		]
    in	
    returnTc (data_ids, andMonoBindList binds)
  where
    data_cons = tyConDataCons tycon
    fields = [ (con, field) | con   <- data_cons,
			      field <- dataConFieldLabels con
	     ]

	-- groups is list of fields that share a common name
    groups = equivClasses cmp_name fields
    cmp_name (_, field1) (_, field2) 
	= fieldLabelName field1 `compare` fieldLabelName field2
\end{code}

\begin{code}
mkRecordSelector tycon fields@((first_con, first_field_label) : other_fields)
		-- These fields all have the same name, but are from
		-- different constructors in the data type
	-- Check that all the fields in the group have the same type
	-- This check assumes that all the constructors of a given
	-- data type use the same type variables
  = checkTc (all (== field_ty) other_tys)
	    (fieldTypeMisMatch field_name)	`thenTc_`
    returnTc selector_id
  where
    field_ty   = fieldLabelType first_field_label
    field_name = fieldLabelName first_field_label
    other_tys  = [fieldLabelType fl | (_, fl) <- other_fields]
    (tyvars, _, _, _, _, _) = dataConSig first_con
    data_ty  = mkTyConApp tycon (mkTyVarTys tyvars)
    -- tyvars of first_con may be free in field_ty
    -- Now build the selector

    selector_ty :: Type
    selector_ty  = mkForAllTys tyvars $	
		   mkFunTy data_ty $
		   field_ty
      
    selector_id :: Id
    selector_id 
      | isNewTyCon tycon    = mkNewTySelId  first_field_label selector_ty
      | otherwise	    = mkRecordSelId first_field_label selector_ty
\end{code}


Errors and contexts
~~~~~~~~~~~~~~~~~~~
\begin{code}
fieldTypeMisMatch field_name
  = sep [ptext SLIT("Declared types differ for field"), quotes (ppr field_name)]

exRecConErr name
  = ptext SLIT("Can't combine named fields with locally-quantified type variables")
    $$
    (ptext SLIT("In the declaration of data constructor") <+> ppr name)
\end{code}
