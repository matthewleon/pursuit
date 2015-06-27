{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE OverloadedStrings #-}

module Model.DocsAsHoogle
  ( packageAsHoogle
  ) where

-- | Functions for rendering generated documentation from PureScript code as
-- | an input file, suitable for supplying to Hoogle to build a database from.

import Prelude
import Data.Foldable (foldMap)
import Data.Monoid
import Data.Version (showVersion)
import qualified Data.Text as T
import qualified Data.Text.Lazy as LT

import qualified Text.Blaze.Html as H
import qualified Text.Blaze.Html.Renderer.Text as H
import qualified Cheapskate

import qualified Language.PureScript as P
import qualified Language.PureScript.Docs as D
import qualified Web.Bower.PackageMeta as Bower

import Model.DocLinks

packageAsHoogle :: D.Package a -> LT.Text
packageAsHoogle pkg@D.Package{..} = preamble <> modules
  where
  preamble =
    LT.unlines [ "@package " <> (LT.pack $ Bower.runPackageName $ D.packageName pkg)
               , "@version " <> (LT.pack $ showVersion $ pkgVersion)
               , ""
               ]
  ctx = getLinksContext pkg
  modules = foldMap renderModule pkgModules
  renderModule m = moduleAsHoogle (ctx, P.moduleNameFromString (D.modName m)) m

codeAsHoogle :: LinksContext' -> D.RenderedCode -> LT.Text
codeAsHoogle ctx = D.outputWith elemAsText
  where
  elemAsText (D.Syntax x)  = LT.pack x
  elemAsText (D.Ident x)   = LT.pack x
  elemAsText (D.Ctor x mn) = qualifyConstructor ctx x mn
  elemAsText (D.Kind x)    = LT.pack x
  elemAsText (D.Keyword x) = LT.pack x
  elemAsText D.Space       = " "

qualifyConstructor :: LinksContext' -> String -> D.ContainingModule -> LT.Text
qualifyConstructor ctx ctor' containMn =
  maybe (LT.pack ctor') render (getLink ctx ctor' containMn)
  where
  render docLink = LT.pack $ case docLink of
    SameModule ctor ->
      show (snd ctx) ++ "." ++ ctor
    LocalModule _ otherMn ctor ->
      show otherMn ++ "." ++ ctor
    DepsModule _ otherPkg _ otherMn ctor ->
      Bower.runPackageName otherPkg ++ ":" ++ show otherMn ++ "." ++ ctor

declAsHoogle :: LinksContext' -> D.Declaration -> LT.Text
declAsHoogle ctx d@D.Declaration{..} =
     commentsAsHoogle declComments
  <> codeAsHoogle ctx (renderDeclaration d)
  <> "\n\n"
  <> foldMap ((<> "\n\n") . childDeclAsHoogle ctx d) declChildren

childDeclAsHoogle :: LinksContext' -> D.Declaration -> D.ChildDeclaration -> LT.Text
childDeclAsHoogle ctx parent d@D.ChildDeclaration{..} =
     commentsAsHoogle cdeclComments
  <> codeAsHoogle ctx (renderChildDeclaration parent d)

moduleAsHoogle :: LinksContext' -> D.Module -> LT.Text
moduleAsHoogle ctx D.Module{..} =
  commentsAsHoogle modComments
    <> "module " <> LT.pack modName <> " where\n\n"
    <> foldMap ((<> "\n\n") . declAsHoogle ctx) modDeclarations

commentsAsHoogle :: Maybe String -> LT.Text
commentsAsHoogle =
  maybe "" (LT.unlines . fmap ("-- | " <>) . LT.lines . renderComments)

renderComments :: String -> LT.Text
renderComments =
  H.renderHtml . H.toHtml . renderMarkdown . T.pack
  where
  renderMarkdown = Cheapskate.markdown Cheapskate.def

renderDeclaration :: D.Declaration -> D.RenderedCode
renderDeclaration = D.renderDeclaration

renderChildDeclaration :: D.Declaration -> D.ChildDeclaration -> D.RenderedCode
renderChildDeclaration parent decl@D.ChildDeclaration{..} =
  case cdeclInfo of
    D.ChildDataConstructor tys ->
      D.ident cdeclTitle <> D.sp <> D.syntax "::" <> D.sp <> D.renderType ty
      where
      ty = P.quantify $ foldr (\a b -> P.TypeApp (P.TypeApp P.tyFunction a) b) parentType tys
      parentType =
        case D.declInfo parent of
          D.DataDeclaration _ args ->
            D.typeApp (D.declTitle parent) args
          _ ->
            invalidArgument $
              "the parent of a data constructor was something other than a "
              <> "data declaration"
    D.ChildTypeClassMember ty ->
      D.ident cdeclTitle <> D.sp <>
        D.syntax "::" <> D.sp <>
        D.renderType (addConstraint classConstraint ty)
      where
      classConstraint =
        case D.declInfo parent of
          D.TypeClassDeclaration args _ ->
            (P.Qualified Nothing (P.ProperName (D.declTitle parent)), map D.toTypeVar args)
          _ ->
            invalidArgument $
              "the parent of a type class member was something other than a "
              <> "type class"

      addConstraint c ty' = P.moveQuantifiersToFront (P.quantify (P.ConstrainedType [c] ty'))
    _ ->
      D.renderChildDeclaration decl
  where
  invalidArgument msg =
    error $ "Invalid argument in Model.DocsAsHoogle.renderChildDeclaration: " <> msg
